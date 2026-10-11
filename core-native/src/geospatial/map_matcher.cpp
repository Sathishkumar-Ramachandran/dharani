#include "geospatial/map_matcher.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <unordered_map>

namespace dharani::geo {
namespace {
constexpr double kNegInf = -std::numeric_limits<double>::infinity();
}

// Shortest on-graph distance between two projected positions, bounded by max_route_detour_m.
double MapMatcher::route_distance(const Candidate& from, const Candidate& to) const {
  const Edge& fe = graph_.edges()[from.edge];
  const Edge& te = graph_.edges()[to.edge];
  const double inf = std::numeric_limits<double>::infinity();

  if (from.edge == to.edge) {
    double delta = to.proj.offset_m - from.proj.offset_m;
    if (delta >= 0 || !fe.oneway) return std::fabs(delta);
    return inf;  // would drive against a one-way edge
  }

  // Dijkstra from the end(s) of the origin edge you can leave through.
  struct Item {
    double d;
    std::uint32_t node;
    bool operator>(const Item& o) const { return d > o.d; }
  };
  std::unordered_map<std::uint32_t, double> dist;
  std::priority_queue<Item, std::vector<Item>, std::greater<>> pq;
  auto push = [&](std::uint32_t node, double d) {
    auto it = dist.find(node);
    if (it == dist.end() || d < it->second) {
      dist[node] = d;
      pq.push({d, node});
    }
  };
  push(fe.b, fe.length_m - from.proj.offset_m);
  if (!fe.oneway) push(fe.a, from.proj.offset_m);

  double best = inf;
  while (!pq.empty()) {
    auto [d, node] = pq.top();
    pq.pop();
    if (d > dist[node] || d > cfg_.max_route_detour_m) continue;
    if (d >= best) break;
    // Entering the destination edge through node a (offset measured from a) or b.
    if (node == te.a) best = std::min(best, d + to.proj.offset_m);
    if (node == te.b && !te.oneway) best = std::min(best, d + te.length_m - to.proj.offset_m);
    for (const Adjacent& adj : graph_.adjacent(node)) push(adj.to, d + graph_.edges()[adj.edge].length_m);
  }
  return best;
}

std::vector<MatchedPoint> MapMatcher::match(const std::vector<RawCoordinate>& trace) const {
  const std::size_t n = trace.size();
  std::vector<MatchedPoint> out(n);
  for (std::size_t i = 0; i < n; ++i) out[i].snapped = {trace[i].lat, trace[i].lon};
  if (n == 0) return out;

  // Candidate generation.
  std::vector<std::vector<Candidate>> cands(n);
  for (std::size_t i = 0; i < n; ++i) {
    const double radius = std::max(cfg_.search_radius_m, trace[i].accuracy_m * 2.0);
    LatLon p{trace[i].lat, trace[i].lon};
    std::vector<Candidate> all;
    for (std::uint32_t e : index_.edges_near(p, radius)) {
      Projection pr = project_onto_edge(graph_, e, p);
      if (pr.distance_m <= radius) all.push_back({e, pr});
    }
    std::sort(all.begin(), all.end(),
              [](const Candidate& a, const Candidate& b) { return a.proj.distance_m < b.proj.distance_m; });
    if (all.size() > cfg_.max_candidates) all.resize(cfg_.max_candidates);
    cands[i] = std::move(all);
  }

  auto emission = [&](std::size_t i, const Candidate& c) {
    double sigma = std::max(cfg_.sigma_z_m, trace[i].accuracy_m);
    return -0.5 * (c.proj.distance_m * c.proj.distance_m) / (sigma * sigma);
  };

  // Viterbi over the maximal runs of observations that have candidates; a gap restarts the chain.
  std::vector<std::vector<double>> score(n);
  std::vector<std::vector<int>> back(n);
  for (std::size_t i = 0; i < n; ++i) {
    score[i].assign(cands[i].size(), kNegInf);
    back[i].assign(cands[i].size(), -1);
    if (cands[i].empty()) continue;
    const bool chained = i > 0 && !cands[i - 1].empty();
    for (std::size_t k = 0; k < cands[i].size(); ++k) {
      double e = emission(i, cands[i][k]);
      if (!chained) {
        score[i][k] = e;
        continue;
      }
      double gc = haversine_m({trace[i - 1].lat, trace[i - 1].lon}, {trace[i].lat, trace[i].lon});
      for (std::size_t j = 0; j < cands[i - 1].size(); ++j) {
        if (score[i - 1][j] == kNegInf) continue;
        double rd = route_distance(cands[i - 1][j], cands[i][k]);
        if (!std::isfinite(rd)) continue;
        double s = score[i - 1][j] + e - std::fabs(gc - rd) / cfg_.beta_m;
        if (s > score[i][k]) {
          score[i][k] = s;
          back[i][k] = static_cast<int>(j);
        }
      }
      if (score[i][k] == kNegInf) score[i][k] = e - 50.0;  // disconnected: restart with a penalty
    }
  }

  // Backtrack each run.
  std::size_t i = n;
  while (i > 0) {
    --i;
    if (cands[i].empty()) continue;
    std::size_t best = 0;
    for (std::size_t k = 1; k < cands[i].size(); ++k)
      if (score[i][k] > score[i][best]) best = k;
    // Confidence: posterior share of the winner among candidates, scaled by GPS-to-road fit.
    double denom = 0;
    for (std::size_t k = 0; k < cands[i].size(); ++k) denom += std::exp(score[i][k] - score[i][best]);
    double share = denom > 0 ? 1.0 / denom : 1.0;
    int cur = static_cast<int>(best);
    std::size_t j = i;
    bool first = true;
    for (;;) {
      const Candidate& c = cands[j][static_cast<std::size_t>(cur)];
      out[j].edge_index = static_cast<std::int32_t>(c.edge);
      out[j].snapped = c.proj.point;
      out[j].confidence = std::exp(emission(j, c)) * (first ? share : 1.0);
      first = false;
      int prev = back[j][static_cast<std::size_t>(cur)];
      if (prev < 0 || j == 0) {
        i = j;
        break;
      }
      cur = prev;
      --j;
    }
  }
  return out;
}

}  // namespace dharani::geo
