#include <cmath>

#include "check.hpp"
#include "escrow_reconciliation.hpp"

using namespace dharani::beckn;
namespace json = dharani::json;

namespace {
constexpr std::int64_t kSec = 1'000'000'000LL;
constexpr std::int64_t kT0 = 1'700'000'000LL;  // epoch seconds

json::Value request(const std::string& txn, std::int64_t t_s, json::Value msg) {
  Context ctx;
  ctx.transaction_id = txn;
  ctx.message_id = "m-" + std::to_string(t_s);
  ctx.bap_id = "consignor.example";
  ctx.bpp_id = "carrier.example";
  ctx.timestamp_ns = t_s * kSec;
  return envelope(ctx, std::move(msg));
}

Rfq make_rfq(const std::string& txn, bool cold) {
  Rfq r;
  r.transaction_id = txn;
  r.consignor_id = "shipper-1";
  r.origin = {"Bengaluru DC", 12.9177, 77.6238, 250};
  r.destination = {"Krishnagiri Hub", 12.5186, 78.2137, 300};
  r.cargo = {42.0, 12.5, cold, 2.0, 8.0};
  r.delivery_deadline_epoch_s = kT0 + 6 * 3600;
  return r;
}

json::Value msg_rfq(const Rfq& r) {
  json::Value m = json::Value::object();
  m.set("rfq", to_json(r));
  return m;
}
json::Value msg_quote(const Quote& q) {
  json::Value m = json::Value::object();
  m.set("quote", to_json(q));
  return m;
}
json::Value state_msg(const char* s) {
  json::Value m = json::Value::object();
  m.set("state", s);
  return m;
}
json::Value telemetry(double lat, double lon, bool tamper, std::optional<double> temp = std::nullopt) {
  json::Value m = json::Value::object();
  m.set("lat", lat).set("lon", lon).set("tamper", tamper).set("signature_valid", true);
  if (temp) m.set("temperature_c", *temp);
  return m;
}

// Drives a contract to IN_TRANSIT through the Beckn actions; returns the ledger.
void to_in_transit(ContractLedger& l, const std::string& txn, bool cold) {
  l.handle("search", request(txn, kT0, msg_rfq(make_rfq(txn, cold))));
  l.handle("on_search", request(txn, kT0 + 1, msg_quote({"carrier-9", "BLR-KRS", 5'000'000, 1'000'000})));
  json::Value sel = json::Value::object();
  sel.set("carrier_id", "carrier-9");
  l.handle("select", request(txn, kT0 + 2, sel));
  l.handle("init", request(txn, kT0 + 3, json::Value::object()));
  l.handle("confirm", request(txn, kT0 + 4, json::Value::object()));
  l.handle("on_update", request(txn, kT0 + 5, state_msg("DISPATCHED")));
  l.handle("on_update", request(txn, kT0 + 6, state_msg("IN_TRANSIT")));
}

std::string state_of(const json::Value& reply) { return reply.get("message").get("state").as_string(); }
}  // namespace

int main() {
  // Pure state machine.
  StateMachine sm;
  CHECK(!sm.transition(ContractState::Settled));          // cannot skip
  CHECK(!sm.transition(ContractState::Disputed));         // nothing escrowed yet
  CHECK(sm.transition(ContractState::Confirmed));
  CHECK(!sm.transition(ContractState::InTransit));        // cannot skip DISPATCHED
  CHECK(sm.transition(ContractState::Dispatched));
  CHECK(sm.transition(ContractState::Disputed));
  CHECK(sm.terminal());
  CHECK(!sm.transition(ContractState::Settled));          // terminal
  CHECK_EQ(to_string(ContractState::GeofenceVerified), "GEOFENCE_VERIFIED");
  CHECK(parse_state("IN_TRANSIT") == ContractState::InTransit);
  CHECK(!parse_state("bogus").has_value());

  {  // Happy path: signed fix inside the destination geofence settles the escrow.
    ContractLedger l;
    to_in_transit(l, "txn-1", false);
    auto r = l.handle("telemetry", request("txn-1", kT0 + 3600, telemetry(12.70, 77.9, false)));
    CHECK_EQ(state_of(r), "IN_TRANSIT");
    r = l.handle("telemetry", request("txn-1", kT0 + 7200, telemetry(12.5187, 78.2138, false)));
    CHECK_EQ(state_of(r), "SETTLED");
    const auto& esc = r.get("message").get("escrow");
    CHECK_EQ(esc.get("paid_to_carrier_paise").as_int(), 5'000'000);
    CHECK_EQ(esc.get("returned_collateral_paise").as_int(), 1'000'000);
    CHECK_EQ(esc.get("freight_held_paise").as_int(), 0);
    CHECK(r.get("message").get("decision").get("release_escrow").as_bool());
    CHECK_EQ(r.get("context").get("action").as_string(), "telemetry");
  }
  {  // Late delivery -> 5% SLA penalty from collateral to the consignor.
    ContractLedger l;
    to_in_transit(l, "txn-late", false);
    auto r = l.handle("telemetry", request("txn-late", kT0 + 8 * 3600, telemetry(12.5186, 78.2137, false)));
    CHECK_EQ(state_of(r), "SETTLED");
    CHECK_EQ(r.get("message").get("escrow").get("refunded_to_consignor_paise").as_int(), 250'000);
    CHECK_EQ(r.get("message").get("escrow").get("paid_to_carrier_paise").as_int(), 4'750'000);
  }
  {  // Tamper flag -> dispute, funds locked, audit routed to arbitration.
    ContractLedger l;
    to_in_transit(l, "txn-2", false);
    auto r = l.handle("telemetry", request("txn-2", kT0 + 100, telemetry(12.8, 77.7, true)));
    CHECK_EQ(state_of(r), "DISPUTED");
    CHECK(r.get("message").get("escrow").get("locked").as_bool());
    CHECK_EQ(r.get("message").get("escrow").get("freight_held_paise").as_int(), 5'000'000);
    CHECK(r.get("message").get("arbitration_pending").as_bool());
    // Once disputed, even a perfect delivery cannot settle.
    r = l.handle("telemetry", request("txn-2", kT0 + 200, telemetry(12.5186, 78.2137, false)));
    CHECK_EQ(state_of(r), "DISPUTED");
    auto audit = l.handle("audit", request("txn-2", kT0 + 300, json::Value::object())).get("message");
    CHECK_EQ(audit.get("arbitration_node").as_string(), "arbitration.dharani.local");
    // Hash chain integrity.
    std::string prev(64, '0');
    for (const auto& e : audit.get("log").as_array()) {
      CHECK_EQ(e.get("prev_hash").as_string(), prev);
      prev = e.get("hash").as_string();
    }
    CHECK_EQ(audit.get("head_hash").as_string(), prev);
    CHECK(audit.get("log").as_array().size() >= 8);
  }
  {  // Cold chain: 15 minutes above the band disputes; a short excursion does not.
    ContractLedger l;
    to_in_transit(l, "txn-cold", true);
    auto r = l.handle("telemetry", request("txn-cold", kT0 + 1000, telemetry(12.7, 77.9, false, 5.0)));
    CHECK_EQ(state_of(r), "IN_TRANSIT");
    r = l.handle("telemetry", request("txn-cold", kT0 + 1060, telemetry(12.7, 77.9, false, 11.0)));   // excursion starts
    r = l.handle("telemetry", request("txn-cold", kT0 + 1060 + 600, telemetry(12.7, 77.9, false, 11.5)));  // 10 min
    CHECK_EQ(state_of(r), "IN_TRANSIT");
    r = l.handle("telemetry", request("txn-cold", kT0 + 1060 + 700, telemetry(12.7, 77.9, false, 4.0)));    // recovered
    CHECK_EQ(state_of(r), "IN_TRANSIT");
    CHECK_NEAR(r.get("message").get("temperature_excursion_s").as_number(), 0.0, 1e-9);
    r = l.handle("telemetry", request("txn-cold", kT0 + 2000, telemetry(12.7, 77.9, false, 12.0)));
    r = l.handle("telemetry", request("txn-cold", kT0 + 2000 + 15 * 60, telemetry(12.7, 77.9, false, 12.0)));
    CHECK_EQ(state_of(r), "IN_TRANSIT");  // exactly 15 min: not yet "more than"
    r = l.handle("telemetry", request("txn-cold", kT0 + 2000 + 15 * 60 + 1, telemetry(12.7, 77.9, false, 12.0)));
    CHECK_EQ(state_of(r), "DISPUTED");
  }
  {  // Protocol violations are rejected without changing state.
    ContractLedger l;
    l.handle("search", request("txn-3", kT0, msg_rfq(make_rfq("txn-3", false))));
    auto expect_throw = [&](const char* action, json::Value msg) {
      try {
        l.handle(action, request("txn-3", kT0 + 1, std::move(msg)));
      } catch (const std::exception&) {
        return true;
      }
      return false;
    };
    CHECK(expect_throw("init", json::Value::object()));             // no selected quote
    CHECK(expect_throw("confirm", json::Value::object()));          // escrow not funded
    CHECK(expect_throw("select", [] { json::Value m = json::Value::object(); m.set("carrier_id", "ghost"); return m; }()));
    CHECK(expect_throw("on_update", state_msg("DISPATCHED")));      // not confirmed
    CHECK(expect_throw("on_status", json::Value::object()) == false);
    CHECK(expect_throw("no_such_action", json::Value::object()));
    CHECK(expect_throw("search", msg_rfq(make_rfq("txn-3", false))));  // duplicate txn
    Rfq bad = make_rfq("txn-4", false);
    bad.cargo.tonnage = -1;
    CHECK(expect_throw("search", msg_rfq(bad)));
    CHECK(l.size() == 1);
    try {
      l.handle("on_status", request("missing", kT0, json::Value::object()));
      CHECK(false);
    } catch (const std::invalid_argument&) {
    }
  }
  {  // EscrowReconciliation helper keeps the original contract.
    Contract c(make_rfq("txn-5", false));
    Quote q{"carrier-9", "lane", 1000, 100};
    c.add_quote(q, 1);
    c.select("carrier-9", 2);
    c.fund_escrow(3);
    c.confirm(4);
    c.advance(ContractState::Dispatched, 5);
    c.advance(ContractState::InTransit, 6);
    EscrowReconciliation rec;
    auto d = rec.assess(c, false, true, std::chrono::minutes(10), 7);
    CHECK(!d.arbitration_required && c.state() == ContractState::InTransit);
    d = rec.assess(c, false, true, std::chrono::minutes(16), 8);
    CHECK(d.arbitration_required && c.state() == ContractState::Disputed);
  }
  {  // JSON round trips.
    Rfq r = make_rfq("rt", true);
    Rfq r2 = rfq_from_json(json::parse(json::dump(to_json(r))));
    CHECK_EQ(r2.transaction_id, "rt");
    CHECK_NEAR(r2.destination.lat, r.destination.lat, 1e-9);
    CHECK(r2.cargo.temperature_controlled);
    CHECK_EQ(r2.delivery_deadline_epoch_s, r.delivery_deadline_epoch_s);
    auto v = json::parse(R"({"a":[1,2.5,{"b":"x\né"}],"c":null,"d":true})");
    CHECK_EQ(v.get("a").as_array().size(), 3u);
    CHECK_EQ(v.get("a").as_array()[2].get("b").as_string(), "x\n\xc3\xa9");
    bool threw = false;
    try { json::parse("{\"a\":"); } catch (const json::ParseError&) { threw = true; }
    CHECK(threw);
  }
  TEST_MAIN_END();
}
