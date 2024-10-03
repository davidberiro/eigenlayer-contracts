// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "src/contracts/permissions/PauserRegistry.sol";

import "src/test/mocks/StrategyManagerMock.sol";
import "src/test/mocks/DelegationManagerMock.sol";
import "src/test/mocks/EigenPodManagerMock.sol";
import "src/test/mocks/AVSDirectoryMock.sol";

contract EmptyContract {}

abstract contract EigenLayerUnitTest is Test {
    Vm constant cheats = Vm(HEVM_ADDRESS);
    address constant pauser = address(555);
    address constant unpauser = address(556);

    address[] pausers;
    mapping(address => bool) isExcludedFuzzAddr;

    PauserRegistry pauserRegistry;
    ProxyAdmin eigenLayerProxyAdmin;
    
    EmptyContract emptyContract = new EmptyContract();

    StrategyManagerMock strategyManagerMock;
    DelegationManagerMock delegationManagerMock;
    EigenPodManagerMock eigenPodManagerMock;
    AVSDirectoryMock avsDirectoryMock;

    /// @dev Usage: `fuzzAddr = bound(fuzzAddr, isExcludedFuzzAddr);`
    function bound(
        address addr, 
        mapping(address => bool) storage isExcluded
    ) internal view returns (address) {
        // If the address is not excluded, return it unchanged.
        if (!isExcluded[addr]) return addr;

        // If the address is excluded, hash the address until it's not excluded.
        while (isExcluded[addr]) {
            addr = address(uint160(uint256(keccak256(abi.encodePacked(addr)))));
        }

        return addr;
    }

    function setUp() public virtual {
        pausers.push(pauser);

        eigenLayerProxyAdmin = new ProxyAdmin();
        pauserRegistry = new PauserRegistry(pausers, unpauser);

        avsDirectoryMock = new AVSDirectoryMock();
        delegationManagerMock = new DelegationManagerMock();
        strategyManagerMock = new StrategyManagerMock();
        eigenPodManagerMock = new EigenPodManagerMock(pauserRegistry);

        isExcludedFuzzAddr[address(0)] = true;
        isExcludedFuzzAddr[address(pauserRegistry)] = true;
        isExcludedFuzzAddr[address(eigenLayerProxyAdmin)] = true;
        isExcludedFuzzAddr[address(strategyManagerMock)] = true;
        isExcludedFuzzAddr[address(delegationManagerMock)] = true;
        isExcludedFuzzAddr[address(eigenPodManagerMock)] = true;
    }

    function _createUpgradeableProxy() internal returns (address proxy) {
        // Create an uninitialized transparent-upgradeable proxy.
        proxy = address(new TransparentUpgradeableProxy(address(emptyContract), address(eigenLayerProxyAdmin), ""));
        // Exclude the proxy from fuzzed inputs.
        isExcludedFuzzAddr[address(0)] = true;
    }
}
