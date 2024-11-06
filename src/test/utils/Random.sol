// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "src/contracts/interfaces/IAllocationManager.sol";
import "src/contracts/interfaces/IStrategy.sol";
import "src/contracts/libraries/OperatorSetLib.sol";

type Randomness is uint256;

using Random for Randomness global;

library Random {
    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @dev Equivalent to: `uint256(keccak256("RANDOMNESS.SEED"))`.
    uint256 constant SEED = 0x93bfe7cafd9427243dc4fe8c6e706851eb6696ba8e48960dd74ecc96544938ce;

    /// @dev Equivalent to: `uint256(keccak256("RANDOMNESS.SLOT"))`.
    uint256 constant SLOT = 0xd0660badbab446a974e6a19901c78a2ad88d7e4f1710b85e1cfc0878477344fd;

    /// -----------------------------------------------------------------------
    /// Helpers
    /// -----------------------------------------------------------------------

    function set(
        Randomness r
    ) internal returns (Randomness) {
        /// @solidity memory-safe-assembly
        assembly {
            sstore(SLOT, r)
        }
        return r;
    }

    function shuffle(
        Randomness r
    ) internal returns (Randomness) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, sload(SLOT))
            mstore(0x20, r)
            r := keccak256(0x00, 0x20)
        }
        return r.set();
    }

    /// -----------------------------------------------------------------------
    /// Native Types
    /// -----------------------------------------------------------------------

    function Uint256(Randomness r, uint256 min, uint256 max) internal returns (uint256) {
        return max <= min ? min : r.Uint256() % (max - min) + min;
    }

    function Uint256(
        Randomness r
    ) internal returns (uint256) {
        return r.shuffle().unwrap();
    }

    function Uint128(Randomness r, uint128 min, uint128 max) internal returns (uint128) {
        return uint128(Uint256(r, min, max));
    }

    function Uint128(
        Randomness r
    ) internal returns (uint128) {
        return uint128(Uint256(r));
    }

    function Uint64(Randomness r, uint64 min, uint64 max) internal returns (uint64) {
        return uint64(Uint256(r, min, max));
    }

    function Uint64(
        Randomness r
    ) internal returns (uint64) {
        return uint64(Uint256(r));
    }

    function Uint32(Randomness r, uint32 min, uint32 max) internal returns (uint32) {
        return uint32(Uint256(r, min, max));
    }

    function Uint32(
        Randomness r
    ) internal returns (uint32) {
        return uint32(Uint256(r));
    }

    function Bytes32(
        Randomness r
    ) internal returns (bytes32) {
        return bytes32(r.Uint256());
    }

    function Address(
        Randomness r
    ) internal returns (address) {
        return address(uint160(r.Uint256(1, type(uint160).max)));
    }

    /// -----------------------------------------------------------------------
    /// General Types
    /// -----------------------------------------------------------------------

    function StrategyArray(Randomness r, uint256 len) internal returns (IStrategy[] memory strategies) {
        strategies = new IStrategy[](len);
        for (uint256 i; i < len; ++i) {
            strategies[i] = IStrategy(r.Address());
        }
    }

    function OperatorSetArray(
        Randomness r,
        address avs,
        uint256 len
    ) internal returns (OperatorSet[] memory operatorSets) {
        operatorSets = new OperatorSet[](len);
        for (uint256 i; i < len; ++i) {
            operatorSets[i] = OperatorSet(avs, r.Uint32());
        }
    }

    /// -----------------------------------------------------------------------
    /// `AllocationManager` Types
    /// -----------------------------------------------------------------------

    /// @dev Usage: `r.createSetParams(r, numOpSets, numStrats)`.
    function CreateSetParams(
        Randomness r,
        uint256 numOpSets,
        uint256 numStrats
    ) internal returns (IAllocationManagerTypes.CreateSetParams[] memory params) {
        params = new IAllocationManagerTypes.CreateSetParams[](numOpSets);
        for (uint256 i; i < numOpSets; ++i) {
            params[i].operatorSetId = r.Uint32(1, type(uint32).max);
            params[i].strategies = r.StrategyArray(numStrats);
        }
    }
    
    /// @dev Usage: 
    /// ```
    /// AllocateParams[] memory allocateParams = r.allocateParams(avs, numAllocations, numStrats);
    /// cheats.prank(avs);
    /// allocationManager.createOperatorSets(r.createSetParams(allocateParams));
    /// ```
    function CreateSetParams(
        Randomness,
        IAllocationManagerTypes.AllocateParams[] memory allocateParams
    ) internal pure returns (IAllocationManagerTypes.CreateSetParams[] memory params) {
        params = new IAllocationManagerTypes.CreateSetParams[](allocateParams.length);
        for (uint256 i; i < allocateParams.length; ++i) {
            params[i] = IAllocationManagerTypes.CreateSetParams(
                allocateParams[i].operatorSet.id, allocateParams[i].strategies
            );
        }
    }
    
    /// @dev Usage: 
    /// ```
    /// AllocateParams[] memory allocateParams = r.allocateParams(avs, numAllocations, numStrats);
    /// CreateSetParams[] memory createSetParams = r.createSetParams(allocateParams);
    /// 
    /// cheats.prank(avs);
    /// allocationManager.createOperatorSets(createSetParams);
    /// 
    /// cheats.prank(operator);
    /// allocationManager.modifyAllocations(allocateParams);
    /// ```
    function AllocateParams(
        Randomness r,
        address avs,
        uint256 numAllocations,
        uint256 numStrats
    ) internal returns (IAllocationManagerTypes.AllocateParams[] memory allocateParams) {
        allocateParams = new IAllocationManagerTypes.AllocateParams[](numAllocations);

        // TODO: Randomize magnitudes such that they sum to 1e18 (100%).
        uint64 magnitudePerSet = uint64(WAD / numStrats);

        for (uint256 i; i < numAllocations; ++i) {
            allocateParams[i].operatorSet = OperatorSet(avs, r.Uint32());
            allocateParams[i].strategies = r.StrategyArray(numStrats);
            allocateParams[i].newMagnitudes = new uint64[](numStrats);

            for (uint256 j; j < numStrats; ++j) {
                allocateParams[i].newMagnitudes[j] = magnitudePerSet;
            }
        }
    }

    /// @dev Usage:
    /// ```
    /// AllocateParams[] memory allocateParams = r.allocateParams(avs, numAllocations, numStrats);
    /// AllocateParams[] memory deallocateParams = r.deallocateParams(allocateParams);
    /// CreateSetParams[] memory createSetParams = r.createSetParams(allocateParams);
    /// 
    /// cheats.prank(avs);
    /// allocationManager.createOperatorSets(createSetParams);
    /// 
    /// cheats.prank(operator);
    /// allocationManager.modifyAllocations(allocateParams);
    ///
    /// cheats.prank(operator)
    /// allocationManager.modifyAllocations(deallocateParams);
    /// ```
    function DeallocateParams(
        Randomness r,
        IAllocationManagerTypes.AllocateParams[] memory allocateParams
    ) internal returns (IAllocationManagerTypes.AllocateParams[] memory deallocateParams) {
        uint256 numDeallocations = allocateParams.length;

        deallocateParams = new IAllocationManagerTypes.AllocateParams[](numDeallocations);

        for (uint256 i; i < numDeallocations; ++i) {
            deallocateParams[i].operatorSet = allocateParams[i].operatorSet;
            deallocateParams[i].strategies = allocateParams[i].strategies;
            
            deallocateParams[i].newMagnitudes = new uint64[](allocateParams[i].strategies.length);
            for (uint256 j; j < allocateParams[i].strategies.length; ++j) {
                deallocateParams[i].newMagnitudes[j] = r.Uint64(0, allocateParams[i].newMagnitudes[j] - 1);
            }
        }
    }

    function RegisterParams(
        Randomness r, 
        address avs, 
        uint256 numOpSets
    ) internal returns (IAllocationManagerTypes.RegisterParams memory params) {
        params.avs = avs;
        params.operatorSetIds = new uint32[](numOpSets);
        for (uint256 i; i < numOpSets; ++i) {
            params.operatorSetIds[i] = r.Uint32(1, type(uint32).max);
        }
        params.data = abi.encode(r.Bytes32());
    }

    function DeregisterParams(
        Randomness,
        address operator,
        IAllocationManagerTypes.RegisterParams memory registerParams
    ) internal pure returns (IAllocationManagerTypes.DeregisterParams memory params) {
        params.operator = operator;
        params.avs = registerParams.avs;
        params.operatorSetIds = registerParams.operatorSetIds;
    }

    /// -----------------------------------------------------------------------
    /// Helpers
    /// -----------------------------------------------------------------------

    function wrap(
        uint256 r
    ) internal pure returns (Randomness) {
        return Randomness.wrap(r);
    }

    function unwrap(
        Randomness r
    ) internal pure returns (uint256) {
        return Randomness.unwrap(r);
    }
}
