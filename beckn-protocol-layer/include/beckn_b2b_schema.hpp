#pragma once
// Beckn-B2B industrial logistics extensions: RFQ, quote and the Beckn message envelopes.
#include <cstdint>
#include <string>

#include "util/json.hpp"

namespace dharani::beckn {

struct Place {
  std::string name;
  double lat{}, lon{};
  double radius_m{250};  // geofence radius used for proof-of-delivery
};

struct Cargo {
  double volume_m3{}, tonnage{};
  bool temperature_controlled{false};
  double min_temp_c{}, max_temp_c{};
};

// Request for quote issued by the Consignor (shipper).
struct Rfq {
  std::string transaction_id, consignor_id;
  Place origin, destination;
  Cargo cargo;
  std::int64_t delivery_deadline_epoch_s{};  // SLA delivery window end
};

// Quote issued by the Fleet Carrier, with the collateral deposit it will escrow.
struct Quote {
  std::string carrier_id, lane_commitment;
  std::int64_t price_paise{}, collateral_paise{};
};

struct Context {
  std::string domain = "dharani:b2b-freight";
  std::string action, transaction_id, message_id, bap_id, bpp_id;
  std::int64_t timestamp_ns{};
  std::string version = "1.1.0";
};

json::Value to_json(const Place&);
json::Value to_json(const Cargo&);
json::Value to_json(const Rfq&);
json::Value to_json(const Quote&);
json::Value to_json(const Context&);

Place place_from_json(const json::Value&);
Cargo cargo_from_json(const json::Value&);
Rfq rfq_from_json(const json::Value&);
Quote quote_from_json(const json::Value&);
Context context_from_json(const json::Value&);

// Throws std::invalid_argument describing the first problem found.
void validate(const Rfq&);
void validate(const Quote&);

// Wraps {"context": ..., "message": ...} as Beckn does.
json::Value envelope(const Context& ctx, json::Value message);

}  // namespace dharani::beckn
