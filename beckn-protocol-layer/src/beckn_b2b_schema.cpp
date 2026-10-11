#include "beckn_b2b_schema.hpp"

#include <cmath>
#include <stdexcept>

namespace dharani::beckn {

json::Value to_json(const Place& p) {
  json::Value v = json::Value::object();
  v.set("name", p.name).set("lat", p.lat).set("lon", p.lon).set("radius_m", p.radius_m);
  return v;
}

json::Value to_json(const Cargo& c) {
  json::Value v = json::Value::object();
  v.set("volume_m3", c.volume_m3).set("tonnage", c.tonnage).set("temperature_controlled", c.temperature_controlled);
  v.set("min_temp_c", c.min_temp_c).set("max_temp_c", c.max_temp_c);
  return v;
}

json::Value to_json(const Rfq& r) {
  json::Value v = json::Value::object();
  v.set("transaction_id", r.transaction_id).set("consignor_id", r.consignor_id);
  v.set("origin", to_json(r.origin)).set("destination", to_json(r.destination)).set("cargo", to_json(r.cargo));
  v.set("delivery_deadline_epoch_s", r.delivery_deadline_epoch_s);
  return v;
}

json::Value to_json(const Quote& q) {
  json::Value v = json::Value::object();
  v.set("carrier_id", q.carrier_id).set("lane_commitment", q.lane_commitment);
  v.set("price_paise", q.price_paise).set("collateral_paise", q.collateral_paise);
  return v;
}

json::Value to_json(const Context& c) {
  json::Value v = json::Value::object();
  v.set("domain", c.domain).set("action", c.action).set("version", c.version);
  v.set("transaction_id", c.transaction_id).set("message_id", c.message_id);
  v.set("bap_id", c.bap_id).set("bpp_id", c.bpp_id).set("timestamp_ns", c.timestamp_ns);
  return v;
}

Place place_from_json(const json::Value& v) {
  Place p;
  p.name = v.get("name").as_string();
  p.lat = v.get("lat").as_number();
  p.lon = v.get("lon").as_number();
  p.radius_m = v.get("radius_m").as_number(250);
  return p;
}

Cargo cargo_from_json(const json::Value& v) {
  Cargo c;
  c.volume_m3 = v.get("volume_m3").as_number();
  c.tonnage = v.get("tonnage").as_number();
  c.temperature_controlled = v.get("temperature_controlled").as_bool();
  c.min_temp_c = v.get("min_temp_c").as_number();
  c.max_temp_c = v.get("max_temp_c").as_number();
  return c;
}

Rfq rfq_from_json(const json::Value& v) {
  Rfq r;
  r.transaction_id = v.get("transaction_id").as_string();
  r.consignor_id = v.get("consignor_id").as_string();
  r.origin = place_from_json(v.get("origin"));
  r.destination = place_from_json(v.get("destination"));
  r.cargo = cargo_from_json(v.get("cargo"));
  r.delivery_deadline_epoch_s = v.get("delivery_deadline_epoch_s").as_int();
  return r;
}

Quote quote_from_json(const json::Value& v) {
  Quote q;
  q.carrier_id = v.get("carrier_id").as_string();
  q.lane_commitment = v.get("lane_commitment").as_string();
  q.price_paise = v.get("price_paise").as_int();
  q.collateral_paise = v.get("collateral_paise").as_int();
  return q;
}

Context context_from_json(const json::Value& v) {
  Context c;
  if (v.has("domain")) c.domain = v.get("domain").as_string();
  c.action = v.get("action").as_string();
  c.transaction_id = v.get("transaction_id").as_string();
  c.message_id = v.get("message_id").as_string();
  c.bap_id = v.get("bap_id").as_string();
  c.bpp_id = v.get("bpp_id").as_string();
  c.timestamp_ns = v.get("timestamp_ns").as_int();
  return c;
}

namespace {
void require_coord(double lat, double lon, const char* what) {
  if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) || (lat == 0 && lon == 0))
    throw std::invalid_argument(std::string(what) + " has invalid coordinates");
}
}  // namespace

void validate(const Rfq& r) {
  if (r.transaction_id.empty()) throw std::invalid_argument("rfq.transaction_id is required");
  if (r.consignor_id.empty()) throw std::invalid_argument("rfq.consignor_id is required");
  require_coord(r.origin.lat, r.origin.lon, "rfq.origin");
  require_coord(r.destination.lat, r.destination.lon, "rfq.destination");
  if (!(r.destination.radius_m > 0)) throw std::invalid_argument("rfq.destination.radius_m must be positive");
  if (!(r.cargo.tonnage > 0)) throw std::invalid_argument("rfq.cargo.tonnage must be positive");
  if (!(r.cargo.volume_m3 > 0)) throw std::invalid_argument("rfq.cargo.volume_m3 must be positive");
  if (r.cargo.temperature_controlled && !(r.cargo.min_temp_c < r.cargo.max_temp_c))
    throw std::invalid_argument("rfq.cargo temperature range is empty");
  if (r.delivery_deadline_epoch_s <= 0) throw std::invalid_argument("rfq.delivery_deadline_epoch_s is required");
}

void validate(const Quote& q) {
  if (q.carrier_id.empty()) throw std::invalid_argument("quote.carrier_id is required");
  if (q.price_paise <= 0) throw std::invalid_argument("quote.price_paise must be positive");
  if (q.collateral_paise < 0) throw std::invalid_argument("quote.collateral_paise must not be negative");
}

json::Value envelope(const Context& ctx, json::Value message) {
  json::Value v = json::Value::object();
  v.set("context", to_json(ctx)).set("message", std::move(message));
  return v;
}

}  // namespace dharani::beckn
