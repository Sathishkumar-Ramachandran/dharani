#include "escrow_reconciliation.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

#include "crypto/sha256.hpp"

namespace dharani::beckn {
namespace {

double distance_m(double lat1, double lon1, double lat2, double lon2) {
  constexpr double kPi = 3.14159265358979323846;
  auto r = [](double d) { return d * kPi / 180.0; };
  double dlat = r(lat2 - lat1), dlon = r(lon2 - lon1);
  double h = std::sin(dlat / 2) * std::sin(dlat / 2) +
             std::cos(r(lat1)) * std::cos(r(lat2)) * std::sin(dlon / 2) * std::sin(dlon / 2);
  return 2 * 6371000.0 * std::atan2(std::sqrt(h), std::sqrt(1 - h));
}

}  // namespace

void Contract::log(std::int64_t ts, std::string event, std::string detail) {
  AuditEntry e;
  e.timestamp_ns = ts;
  e.event = std::move(event);
  e.detail = std::move(detail);
  e.prev_hash = audit_.empty() ? std::string(64, '0') : audit_.back().hash;
  crypto::Sha256 h;
  h.update(e.prev_hash).update(std::to_string(ts)).update(e.event).update(e.detail);
  auto d = h.finish();
  e.hash = crypto::to_hex(d);
  audit_.push_back(std::move(e));
}

void Contract::open(std::int64_t ts) {
  log(ts, "search", "rfq from " + rfq_.consignor_id + " tonnage=" + std::to_string(rfq_.cargo.tonnage));
}

void Contract::add_quote(const Quote& q, std::int64_t ts) {
  validate(q);
  if (sm_.state() != ContractState::Draft) throw std::logic_error("quotes are only accepted while DRAFT");
  quotes_.push_back(q);
  quote_ = q;
  log(ts, "on_search", "quote from " + q.carrier_id + " price=" + std::to_string(q.price_paise) +
                           " collateral=" + std::to_string(q.collateral_paise));
}

void Contract::select(const std::string& carrier_id, std::int64_t ts) {
  if (sm_.state() != ContractState::Draft) throw std::logic_error("select is only valid while DRAFT");
  if (funded_) throw std::logic_error("escrow already funded; a carrier cannot be changed");
  auto it = std::find_if(quotes_.begin(), quotes_.end(), [&](const Quote& q) { return q.carrier_id == carrier_id; });
  if (it == quotes_.end()) throw std::invalid_argument("no quote from carrier " + carrier_id);
  selected_ = *it;
  log(ts, "select", "carrier " + carrier_id);
}

void Contract::fund_escrow(std::int64_t ts) {
  if (!selected_) throw std::logic_error("init requires a selected quote");
  if (funded_) throw std::logic_error("escrow already funded");
  escrow_.freight_held_paise = selected_->price_paise;
  escrow_.collateral_held_paise = selected_->collateral_paise;
  funded_ = true;
  log(ts, "init", "escrow funded freight=" + std::to_string(escrow_.freight_held_paise) +
                      " collateral=" + std::to_string(escrow_.collateral_held_paise));
}

bool Contract::confirm(std::int64_t ts) {
  if (!funded_) throw std::logic_error("confirm requires funded escrow");
  bool ok = sm_.transition(ContractState::Confirmed);
  if (ok) log(ts, "confirm", "contract confirmed");
  return ok;
}

bool Contract::advance(ContractState next, std::int64_t ts) {
  if (next != ContractState::Dispatched && next != ContractState::InTransit)
    throw std::invalid_argument("advance only handles DISPATCHED and IN_TRANSIT");
  bool ok = sm_.transition(next);
  if (ok) log(ts, "on_update", std::string(to_string(next)));
  return ok;
}

void Contract::dispute(const std::string& reason, std::int64_t ts) {
  if (!sm_.transition(ContractState::Disputed)) return;
  escrow_.locked = true;  // collateral and freight stay held
  arbitration_pending_ = true;
  log(ts, "dispute", reason + "; escrow locked; audit log routed to arbitration node");
}

void Contract::settle(std::int64_t ts, bool late) {
  if (!sm_.transition(ContractState::Settled)) return;
  std::int64_t penalty = 0;
  if (late) penalty = std::min(escrow_.collateral_held_paise, escrow_.freight_held_paise / 20);  // 5% SLA penalty
  escrow_.paid_to_carrier_paise = escrow_.freight_held_paise - penalty;
  escrow_.refunded_to_consignor_paise = penalty;
  escrow_.returned_collateral_paise = escrow_.collateral_held_paise - penalty;
  escrow_.freight_held_paise = 0;
  escrow_.collateral_held_paise = 0;
  log(ts, "settle", "paid=" + std::to_string(escrow_.paid_to_carrier_paise) +
                        " collateral_returned=" + std::to_string(escrow_.returned_collateral_paise) +
                        " late_penalty=" + std::to_string(penalty));
}

AuditDecision Contract::observe(const TelemetryObservation& obs) {
  if (sm_.state() != ContractState::InTransit && sm_.state() != ContractState::GeofenceVerified)
    return {false, false, "contract is not in transit"};

  if (obs.tamper || !obs.signature_valid) {
    std::string why = obs.tamper ? "tamper flag raised by attestation engine" : "telemetry signature invalid";
    dispute(why, obs.timestamp_ns);
    return {false, true, why};
  }

  if (rfq_.cargo.temperature_controlled && obs.temperature_c) {
    double t = *obs.temperature_c;
    bool out = t < rfq_.cargo.min_temp_c || t > rfq_.cargo.max_temp_c;
    if (out) {
      if (excursion_start_ns_ < 0) {
        excursion_start_ns_ = obs.timestamp_ns;
        log(obs.timestamp_ns, "temperature_excursion_start", "t=" + std::to_string(t));
      }
      excursion_ns_ = obs.timestamp_ns - excursion_start_ns_;
      if (excursion_ns_ > kExcursionLimitNs) {
        std::string why = "temperature outside SLA band for more than 15 minutes";
        dispute(why, obs.timestamp_ns);
        return {false, true, why};
      }
    } else if (excursion_start_ns_ >= 0) {
      log(obs.timestamp_ns, "temperature_excursion_end", "duration_ns=" + std::to_string(excursion_ns_));
      excursion_start_ns_ = -1;
      excursion_ns_ = 0;
    }
  }

  const Place& d = rfq_.destination;
  if (sm_.state() == ContractState::InTransit && distance_m(obs.lat, obs.lon, d.lat, d.lon) <= d.radius_m) {
    sm_.transition(ContractState::GeofenceVerified);
    log(obs.timestamp_ns, "geofence_verified", "signed fix inside destination geofence");
    bool late = (obs.timestamp_ns / 1000000000LL) > rfq_.delivery_deadline_epoch_s;
    settle(obs.timestamp_ns, late);
    return {true, false, late ? "settled with SLA penalty (late delivery)" : "geofence and SLA verified"};
  }
  return {false, false, "in transit"};
}

AuditDecision EscrowReconciliation::assess(Contract& c, bool tamper, bool hot, std::chrono::minutes d,
                                           std::int64_t ts) const {
  if (tamper || (hot && d > std::chrono::minutes(15))) {
    std::string why = tamper ? "tamper attestation" : "temperature SLA exceeded for more than 15 minutes";
    c.dispute(why, ts);
    return {false, true, why};
  }
  if (c.state() == ContractState::Settled) return {true, false, "already settled"};
  return {false, false, "awaiting geofence verification"};
}

json::Value Contract::to_json() const {
  json::Value v = json::Value::object();
  v.set("transaction_id", rfq_.transaction_id).set("state", std::string(beckn::to_string(sm_.state())));
  v.set("rfq", beckn::to_json(rfq_));
  json::Value qs = json::Value::array();
  for (const auto& q : quotes_) qs.push(beckn::to_json(q));
  v.set("quotes", qs);
  v.set("selected", selected_ ? beckn::to_json(*selected_) : json::Value());
  json::Value e = json::Value::object();
  e.set("funded", funded_).set("locked", escrow_.locked);
  e.set("freight_held_paise", escrow_.freight_held_paise).set("collateral_held_paise", escrow_.collateral_held_paise);
  e.set("paid_to_carrier_paise", escrow_.paid_to_carrier_paise);
  e.set("refunded_to_consignor_paise", escrow_.refunded_to_consignor_paise);
  e.set("returned_collateral_paise", escrow_.returned_collateral_paise);
  v.set("escrow", e);
  v.set("arbitration_pending", arbitration_pending_);
  v.set("temperature_excursion_s", static_cast<double>(excursion_ns_) / 1e9);
  v.set("audit_entries", static_cast<std::int64_t>(audit_.size()));
  return v;
}

json::Value Contract::audit_package() const {
  json::Value v = json::Value::object();
  v.set("transaction_id", rfq_.transaction_id).set("arbitration_node", "arbitration.dharani.local");
  v.set("state", std::string(beckn::to_string(sm_.state())));
  json::Value log_arr = json::Value::array();
  for (const auto& e : audit_) {
    json::Value x = json::Value::object();
    x.set("timestamp_ns", e.timestamp_ns).set("event", e.event).set("detail", e.detail);
    x.set("prev_hash", e.prev_hash).set("hash", e.hash);
    log_arr.push(x);
  }
  v.set("log", log_arr);
  v.set("head_hash", audit_.empty() ? std::string(64, '0') : audit_.back().hash);
  return v;
}

// -------------------------------------------------------------------------------------------
Contract& ContractLedger::require(const std::string& txn) {
  auto it = contracts_.find(txn);
  if (it == contracts_.end()) throw std::invalid_argument("unknown transaction_id " + txn);
  return it->second;
}

std::size_t ContractLedger::size() const {
  std::lock_guard lock(mu_);
  return contracts_.size();
}

json::Value ContractLedger::handle(const std::string& action, const json::Value& request) {
  std::lock_guard lock(mu_);
  Context ctx = context_from_json(request.get("context"));
  const json::Value& msg = request.get("message");
  const std::int64_t ts = ctx.timestamp_ns;
  Context reply_ctx = ctx;
  json::Value out = json::Value::object();

  if (action == "search") {
    Rfq rfq = rfq_from_json(msg.get("rfq"));
    if (rfq.transaction_id.empty()) rfq.transaction_id = ctx.transaction_id;
    validate(rfq);
    if (contracts_.count(rfq.transaction_id)) throw std::invalid_argument("transaction_id already exists");
    auto it = contracts_.emplace(rfq.transaction_id, Contract(rfq)).first;
    reply_ctx.transaction_id = rfq.transaction_id;
    it->second.open(ts);
    out = it->second.to_json();
  } else if (action == "on_search") {
    Contract& c = require(ctx.transaction_id);
    c.add_quote(quote_from_json(msg.get("quote")), ts);
    out = c.to_json();
  } else if (action == "select") {
    Contract& c = require(ctx.transaction_id);
    c.select(msg.get("carrier_id").as_string(), ts);
    out = c.to_json();
  } else if (action == "init") {
    Contract& c = require(ctx.transaction_id);
    c.fund_escrow(ts);
    out = c.to_json();
  } else if (action == "confirm") {
    Contract& c = require(ctx.transaction_id);
    if (!c.confirm(ts)) throw std::logic_error("contract cannot be confirmed in its current state");
    out = c.to_json();
  } else if (action == "on_update") {
    Contract& c = require(ctx.transaction_id);
    auto next = parse_state(msg.get("state").as_string());
    if (!next) throw std::invalid_argument("unknown state");
    if (!c.advance(*next, ts)) throw std::logic_error("illegal transition to " + msg.get("state").as_string());
    out = c.to_json();
  } else if (action == "on_status") {
    out = require(ctx.transaction_id).to_json();
  } else if (action == "telemetry") {
    Contract& c = require(ctx.transaction_id);
    TelemetryObservation o;
    o.timestamp_ns = ts;
    o.lat = msg.get("lat").as_number();
    o.lon = msg.get("lon").as_number();
    o.tamper = msg.get("tamper").as_bool();
    o.signature_valid = msg.has("signature_valid") ? msg.get("signature_valid").as_bool() : true;
    if (msg.has("temperature_c")) o.temperature_c = msg.get("temperature_c").as_number();
    AuditDecision d = c.observe(o);
    out = c.to_json();
    json::Value dec = json::Value::object();
    dec.set("release_escrow", d.release_escrow).set("arbitration_required", d.arbitration_required);
    dec.set("reason", d.reason);
    out.set("decision", dec);
  } else if (action == "dispute") {
    Contract& c = require(ctx.transaction_id);
    c.dispute(msg.get("reason").as_string(), ts);
    out = c.to_json();
  } else if (action == "audit") {
    out = require(ctx.transaction_id).audit_package();
  } else {
    throw std::invalid_argument("unsupported beckn action: " + action);
  }
  reply_ctx.action = action == "search" || action == "select" || action == "init" || action == "confirm"
                         ? "on_" + action
                         : action;
  if (action.rfind("on_", 0) == 0) reply_ctx.action = action;
  return envelope(reply_ctx, std::move(out));
}

}  // namespace dharani::beckn
