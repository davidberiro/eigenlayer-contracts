// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "forge-std/Test.sol";
import "../../contracts/interfaces/IServiceManager.sol";
import "../../contracts/interfaces/ISlasher.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract ServiceManagerMock is IServiceManager, Test {
    ISlasher public slasher;

    constructor(ISlasher _slasher) {
        slasher = _slasher;
    }

    /// @notice Returns the current 'taskNumber' for the middleware
    function taskNumber() external pure returns (uint32) {
        return 0;
    }

    /// @notice Permissioned function that causes the ServiceManager to freeze the operator on EigenLayer, through a call to the Slasher contract
    function freezeOperator(address operator) external {
        slasher.freezeOperator(operator);
    }
    
    /// @notice Permissioned function to have the ServiceManager forward a call to the slasher, recording an initial stake update (on operator registration)
    function recordFirstStakeUpdate(address operator, uint32 serveUntil) external pure {}

    /// @notice Permissioned function to have the ServiceManager forward a call to the slasher, recording a stake update
    function recordStakeUpdate(address operator, uint32 updateBlock, uint32 serveUntilBlock, uint256 prevElement) external pure {}

    /// @notice Permissioned function to have the ServiceManager forward a call to the slasher, recording a final stake update (on operator deregistration)
    function recordLastStakeUpdateAndRevokeSlashingAbility(address operator, uint32 serveUntil) external pure {}

    /// @notice Token used for placing guarantee on challenges & payment commits
    function paymentChallengeToken() external pure returns (IERC20) {
        return IERC20(address(0));
    }

    // @notice The service's VoteWeigher contract, which could be this contract itself
    function voteWeigher() external pure returns (IVoteWeigher) {
        return IVoteWeigher(address(0));
    }

    // @notice The service's PaymentManager contract, which could be this contract itself
    function paymentManager() external pure returns (IPaymentManager) {
        return IPaymentManager(address(0));
    }

    /// @notice Returns the `latestServeUntilBlock` until which operators must serve.
    function latestServeUntilBlock() external pure returns (uint32) {
        return type(uint32).max;
    }

    function owner() external pure returns (address) {
        return address(0);
    }
}