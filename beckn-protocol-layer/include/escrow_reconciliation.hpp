#pragma once
// Escrow, tamper-evident audit log and the contract ledger that implements the Beckn actions.
#include <chrono>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "beckn_b2b_schema.hpp"
#include "state_machine.hpp"

namespace dharani::beckn {

struct EscrowAccount {
  std::int64_t freight_held_paise{0};     // consignor's payment, held by the escrow engine
  std::int64_t collateral_held_paise{0};  // carrier's deposit
  std::int64_t paid_to_carrier_paise{0};
  std::int64_t refunded_to_consignor_paise{0};
  std::int64_t returned_collateral_paise{0};
  bool locked{false};
};

// Hash-chained: hash = SHA256(prev_hash || timestamp || event || detail).
struct AuditEntry {
  std::int64_t timestamp_ns{};
  std::string event, detail, prev_hash, hash;
};

struct TelemetryObservation {
  std::int64_t timestamp_ns{};
  double lat{}, lon{};
  bool tamper{false};
  bool signature_valid{true};
  std::optional<double> temperature_c;
};

struct AuditDecision {
  bool release_escrow{false};
  bool arbitration_required{false};
  std::string reason;
};

class Contract {
 public:
  Contract(Rfq rfq) : rfq_(std::move(rfq)) {}

  const Rfq& rfq() const { return rfq_; }
  const std::optional<Quote>& quote() const { return quote_; }
  const std::optional<Quote>& selected() const { return selected_; }
  ContractState state() const { return sm_.state(); }
  const EscrowAccount& escrow() const { return escrow_; }
  const std::vector<AuditEntry>& audit() const { return audit_; }
  const std::vector<Quote>& quotes() const { return quotes_; }
  bool escrow_funded() const { return funded_; }
  bool arbitration_pending() const { return arbitration_pending_; }
  std::int64_t temperature_excursion_ns() const { return excursion_ns_; }

  void open(std::int64_t ts);                        // beckn "search": records the RFQ
  void add_quote(const Quote& q, std::int64_t ts);
  void select(const std::string& carrier_id, std::int64_t ts);
  void fund_escrow(std::int64_t ts);                 // beckn "init"
  bool confirm(std::int64_t ts);                     // DRAFT -> CONFIRMED
  bool advance(ContractState next, std::int64_t ts); // CONFIRMED -> ... -> IN_TRANSIT
  // Consumes one signed telemetry observation while the vehicle is in transit. May move the
  // contract to GEOFENCE_VERIFIED, SETTLED or DISPUTED.
  AuditDecision observe(const TelemetryObservation& obs);
  void dispute(const std::string& reason, std::int64_t ts);
  json::Value to_json() const;
  json::Value audit_package() const;  // what is handed to the arbitration node

  static constexpr std::int64_t kExcursionLimitNs = 15LL * 60 * 1000000000LL;

 private:
  void log(std::int64_t ts, std::string event, std::string detail);
  void settle(std::int64_t ts, bool late);

  Rfq rfq_;
  std::vector<Quote> quotes_;
  std::optional<Quote> quote_, selected_;
  StateMachine sm_;
  EscrowAccount escrow_;
  std::vector<AuditEntry> audit_;
  bool funded_{false};
  bool arbitration_pending_{false};
  std::int64_t excursion_start_ns_{-1};
  std::int64_t excursion_ns_{0};
};

// Independent assessment helper retained for callers that evaluate a contract from raw flags.
class EscrowReconciliation {
 public:
  AuditDecision assess(Contract& c, bool tamper, bool temperature_out_of_range, std::chrono::minutes duration,
                       std::int64_t timestamp_ns = 0) const;
};

// Thread-safe registry of contracts speaking the Beckn action vocabulary.
//   search / on_search / select / init / confirm / on_update / on_status / telemetry / dispute / audit
class ContractLedger {
 public:
  // `request` is {"context": {...}, "message": {...}}; the reply has the same shape.
  json::Value handle(const std::string& action, const json::Value& request);
  std::size_t size() const;

 private:
  Contract& require(const std::string& txn);
  mutable std::mutex mu_;
  std::map<std::string, Contract> contracts_;
};

}  // namespace dharani::beckn
