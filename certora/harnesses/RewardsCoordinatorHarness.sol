// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "../../src/contracts/core/RewardsCoordinator.sol";

contract RewardsCoordinatorHarness is RewardsCoordinator {
    constructor(
        IDelegationManager _delegationManager,
        IStrategyManager _strategyManager,
        IAVSDirectory _avsDirectory,
        uint32 _CALCULATION_INTERVAL_SECONDS,
        uint32 _MAX_REWARDS_DURATION,
        uint32 _MAX_RETROACTIVE_LENGTH,
        uint32 _MAX_FUTURE_LENGTH,
        uint32 _GENESIS_REWARDS_TIMESTAMP,
        uint32 _OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP,
        uint32 _OPERATOR_SET_MAX_RETROACTIVE_LENGTH
    ) RewardsCoordinator(
        _delegationManager,
        _strategyManager,
        _avsDirectory,
        _CALCULATION_INTERVAL_SECONDS,
        _MAX_REWARDS_DURATION,
        _MAX_RETROACTIVE_LENGTH,
        _MAX_FUTURE_LENGTH,
        _GENESIS_REWARDS_TIMESTAMP,
        _OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP,
        _OPERATOR_SET_MAX_RETROACTIVE_LENGTH
    ) {}

    function operatorCommissionUpdatesArray(address operator, address avs, uint32 operatorSetId, RewardType rewardType)
        public
        view
        returns (OperatorCommissionUpdate[] memory)
    {
        return operatorCommissionUpdates[operator][avs][operatorSetId][rewardType];
    }
}
