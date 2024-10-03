// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "src/contracts/core/AllocationManager.sol";
import "src/contracts/core/AVSDirectory.sol";

import "src/contracts/interfaces/IAVSDirectory.sol";
import "src/contracts/interfaces/IDelegationManager.sol";

import "src/test/utils/EigenLayerUnitTest.sol";

abstract contract AllocationManagerUnitTest is
    EigenLayerUnitTest,
    IAllocationManagerEvents,
    IAllocationManagerErrors
{
    uint256 internal constant MAX_PRIVATE_KEY = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140;
    uint32 internal constant DEALLOCATION_DELAY = 17.5 days;
    uint32 internal constant ALLOCATION_CONFIGURATION_DELAY = 21 days;
    uint32 internal constant MIN_WITHDRAWAL_DELAY = 17.5 days;
    uint32 internal constant MIN_WITHDRAWAL_DELAY_BLOCKS = 216_000;

    AllocationManager allocationManager;

    function setUp() public virtual override {
        EigenLayerUnitTest.setUp();

        address implementation = address(
            new AllocationManager(
                IDelegationManager(delegationManagerMock),
                IAVSDirectory(avsDirectoryMock),
                DEALLOCATION_DELAY,
                ALLOCATION_CONFIGURATION_DELAY
            )
        );

        // Deploy the AllocationManager contract.
        allocationManager = AllocationManager(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(eigenLayerProxyAdmin),
                    abi.encodeWithSelector(
                        AllocationManager.initialize.selector,
                        address(this),
                        pauserRegistry,
                        0 // 0 is initialPausedStatus
                    )
                )
            )
        );

        isExcludedFuzzAddr[address(allocationManager)] = true;
    }

    function test_setAllocationDelay(
        uint256 r
    ) public {
        // Create a non-excluded fuzz addr (operator).
        address operator = bound(address(uint160(r)), isExcludedFuzzAddr);
        // Create a delay, valid or unvalid.
        uint32 newDelay = uint32(bound(r, 0, type(uint32).max));

        // Cache allocation delay info before mutating state.
        (bool isSet, uint32 delay) = allocationManager.allocationDelay(operator);

        assertEq(delay, 0); // sanity check

        // Set the allocation delay based on the role:
        // - As the operator if fuzz randomness `r` is even.
        // - As the delegation manager if fuzz randomness `r` is odd.
        bool asOperatorOrDelgationManager = r % 2 == 0;

        bool reverted;

        if (asOperatorOrDelgationManager) {
            // Assert only registered operators can set their allocation delay.
            cheats.prank(operator);
            cheats.expectRevert(IAllocationManagerErrors.OperatorNotRegistered.selector);
            allocationManager.setAllocationDelay(newDelay);

            // Register the operator.
            delegationManagerMock.setIsOperator(operator, true);

            // Expect a revert if the new delay is 0.
            if (newDelay == 0) {
                cheats.expectRevert(IAllocationManagerErrors.InvalidDelay.selector);
                reverted = true;
            }

            // Set the allocation delay.
            cheats.prank(operator);
            allocationManager.setAllocationDelay(newDelay);
        } else {
            cheats.expectRevert(IAllocationManagerErrors.OnlyDelegationManager.selector);
            allocationManager.setAllocationDelay(operator, newDelay);

            // Expect a revert if the new delay is 0.
            if (newDelay == 0) {
                cheats.expectRevert(IAllocationManagerErrors.InvalidDelay.selector);
                reverted = true;
            }

            // Set the allocation delay.
            cheats.prank(address(delegationManagerMock));
            allocationManager.setAllocationDelay(operator, newDelay);
        }

        // If the run did not revert, assert the allocation delay was set correctly.
        if (!reverted) {
            (bool isSetAfter, uint32 delayAfter) = allocationManager.allocationDelay(operator);
            // Assert `isSet` was properly mutated.
            assertTrue(isSet != isSetAfter);
            // Assert `delay` was properly mutated.
            assertEq(delayAfter, newDelay);
        }
    }

    
}
