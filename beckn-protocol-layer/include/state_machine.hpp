#pragma once
// DRAFT -> CONFIRMED -> DISPATCHED -> IN_TRANSIT -> GEOFENCE_VERIFIED -> SETTLED | DISPUTED
#include <optional>
#include <string_view>

namespace dharani::beckn {

enum class ContractState { Draft, Confirmed, Dispatched, InTransit, GeofenceVerified, Settled, Disputed };

std::string_view to_string(ContractState s);
std::optional<ContractState> parse_state(std::string_view name);

// Pure transition table. DISPUTED is reachable from every state after DRAFT; SETTLED and
// DISPUTED are terminal.
bool can_transition(ContractState from, ContractState to);

class StateMachine {
 public:
  ContractState state() const { return state_; }
  bool transition(ContractState next);  // false (and no change) when illegal
  bool terminal() const { return state_ == ContractState::Settled || state_ == ContractState::Disputed; }
  static std::string_view name(ContractState s) { return to_string(s); }

 private:
  ContractState state_{ContractState::Draft};
};

}  // namespace dharani::beckn
