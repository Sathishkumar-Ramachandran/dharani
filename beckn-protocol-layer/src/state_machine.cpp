#include "state_machine.hpp"

namespace dharani::beckn {

std::string_view to_string(ContractState s) {
  switch (s) {
    case ContractState::Draft: return "DRAFT";
    case ContractState::Confirmed: return "CONFIRMED";
    case ContractState::Dispatched: return "DISPATCHED";
    case ContractState::InTransit: return "IN_TRANSIT";
    case ContractState::GeofenceVerified: return "GEOFENCE_VERIFIED";
    case ContractState::Settled: return "SETTLED";
    case ContractState::Disputed: return "DISPUTED";
  }
  return "UNKNOWN";
}

std::optional<ContractState> parse_state(std::string_view n) {
  for (auto s : {ContractState::Draft, ContractState::Confirmed, ContractState::Dispatched,
                 ContractState::InTransit, ContractState::GeofenceVerified, ContractState::Settled,
                 ContractState::Disputed})
    if (to_string(s) == n) return s;
  return std::nullopt;
}

bool can_transition(ContractState from, ContractState to) {
  if (from == ContractState::Settled || from == ContractState::Disputed) return false;
  if (to == ContractState::Disputed) return from != ContractState::Draft;
  return static_cast<int>(to) == static_cast<int>(from) + 1 && to != ContractState::Disputed;
}

bool StateMachine::transition(ContractState next) {
  if (!can_transition(state_, next)) return false;
  state_ = next;
  return true;
}

}  // namespace dharani::beckn
