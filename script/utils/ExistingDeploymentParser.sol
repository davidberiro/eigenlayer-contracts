// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "../../src/contracts/core/StrategyManager.sol";
import "../../src/contracts/core/DelegationManager.sol";
import "../../src/contracts/core/AVSDirectory.sol";
import "../../src/contracts/core/RewardsCoordinator.sol";
import "../../src/contracts/core/AllocationManager.sol";
import "../../src/contracts/permissions/PermissionController.sol";

import "../../src/contracts/strategies/StrategyFactory.sol";
import "../../src/contracts/strategies/StrategyBase.sol";
import "../../src/contracts/strategies/StrategyBaseTVLLimits.sol";
import "../../src/contracts/strategies/EigenStrategy.sol";

import "../../src/contracts/pods/EigenPod.sol";
import "../../src/contracts/pods/EigenPodManager.sol";

import "../../src/contracts/permissions/PauserRegistry.sol";

import "../../src/test/mocks/EmptyContract.sol";

import "../../src/contracts/interfaces/IBackingEigen.sol";
import "../../src/contracts/interfaces/IEigen.sol";

import "forge-std/Script.sol";

import "src/test/utils/Logger.t.sol";

struct StrategyUnderlyingTokenConfig {
    address tokenAddress;
    string tokenName;
    string tokenSymbol;
}

struct DeployedEigenPods {
    address[] multiValidatorPods;
    address[] singleValidatorPods;
    address[] inActivePods;
}

struct EigenLayer {
    // Administration
    address executorMultisig;
    address operationsMultisig;
    address communityMultisig;
    address pauserMultisig;
    address timelock;
    ProxyAdmin proxyAdmin;
    ProxyAdmin tokenProxyAdmin;
    PauserRegistry pauserRegistry;
    UpgradeableBeacon eigenPodBeacon;
    UpgradeableBeacon strategyBeacon;
    // Core
    AllocationManager allocationManager;
    AllocationManager allocationManagerImpl;
    AVSDirectory avsDirectory;
    AVSDirectory avsDirectoryImpl;
    DelegationManager delegationManager;
    DelegationManager delegationManagerImpl;
    EigenPodManager eigenPodManager;
    EigenPodManager eigenPodManagerImpl;
    EigenPod eigenPodImpl;
    PermissionController permissionController;
    PermissionController permissionControllerImpl;
    RewardsCoordinator rewardsCoordinator;
    RewardsCoordinator rewardsCoordinatorImpl;
    StrategyManager strategyManager;
    StrategyManager strategyManagerImpl;
    StrategyFactory strategyFactory;
    StrategyFactory strategyFactoryImpl;
    StrategyBase baseStrategyImpl;
    StrategyBase strategyFactoryBeaconImpl;
    // Token
    IEigen EIGEN;
    IEigen EIGENImpl;
    IBackingEigen bEIGEN;
    IBackingEigen bEIGENImpl;
    EigenStrategy eigenStrategy;
    EigenStrategy eigenStrategyImpl;
    // Utils
    EmptyContract emptyContract;
    DeployedEigenPods deployedEigenPods;
    StrategyBase[] deployedStrategies;
    StrategyUnderlyingTokenConfig[] strategiesToDeploy;
}

struct EigenLayerInitializationParams {
    // AllocationManager
    uint256 ALLOCATION_MANAGER_INIT_PAUSED_STATUS;
    uint32 DEALLOCATION_DELAY;
    uint32 ALLOCATION_CONFIGURATION_DELAY;
    // AVSDirectory
    uint256 AVS_DIRECTORY_INIT_PAUSED_STATUS;
    // DelegationManager
    uint256 DELEGATION_MANAGER_INIT_PAUSED_STATUS;
    uint32 DELEGATION_MANAGER_MIN_WITHDRAWAL_DELAY_BLOCKS;
    // EigenPodManager
    uint256 EIGENPOD_MANAGER_INIT_PAUSED_STATUS;
    // EigenPod
    uint64 EIGENPOD_GENESIS_TIME;
    uint64 EIGENPOD_MAX_RESTAKED_BALANCE_GWEI_PER_VALIDATOR;
    address ETHPOSDepositAddress;
    // RewardsCoordinator
    uint256 REWARDS_COORDINATOR_INIT_PAUSED_STATUS;
    uint32 REWARDS_COORDINATOR_MAX_REWARDS_DURATION;
    uint32 REWARDS_COORDINATOR_MAX_RETROACTIVE_LENGTH;
    uint32 REWARDS_COORDINATOR_MAX_FUTURE_LENGTH;
    uint32 REWARDS_COORDINATOR_GENESIS_REWARDS_TIMESTAMP;
    address REWARDS_COORDINATOR_UPDATER;
    uint32 REWARDS_COORDINATOR_ACTIVATION_DELAY;
    uint32 REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS;
    uint32 REWARDS_COORDINATOR_DEFAULT_OPERATOR_SPLIT_BIPS;
    uint32 REWARDS_COORDINATOR_OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP;
    uint32 REWARDS_COORDINATOR_OPERATOR_SET_MAX_RETROACTIVE_LENGTH;
    // StrategyManager
    uint256 STRATEGY_MANAGER_INIT_PAUSED_STATUS;
    address STRATEGY_MANAGER_WHITELISTER;
    // Strategy Deployment
    uint256 STRATEGY_MAX_PER_DEPOSIT;
    uint256 STRATEGY_MAX_TOTAL_DEPOSITS;
}

library DeploymentParserLib {
    using DeploymentParserLib for string;

    /// -----------------------------------------------------------------------
    /// Parsing
    /// -----------------------------------------------------------------------

    function parseUint(string memory json, string memory key) internal pure returns (uint256 result) {
        require((result = json.readUint(key)) != 0, string.concat("Zero value provided for: ", key));
    }

    function parseAddress(string memory json, string memory key) internal pure returns (address result) {
        require((result = json.parseAddress(key)) != address(0), string.concat("Zero addresses provided for: ", key));
    }

    function parseAddressArray(string memory json, string memory key) internal pure returns (address[] memory result) {
        result = json.parseAddressArray(key);
        for (uint256 i = 0; i < result.length; ++i) {
            require(result[i] != address(0), string.concat("Zero addresses provided for: ", key));
        }
    }

    function parseDeployedStrategies(
        string memory json
    ) internal pure returns (StrategyBase[] memory result) {
        uint256 len = json.parseUint(".addresses.numStrategiesDeployed");
        StrategyBase[] memory deployedStrategies = new StrategyBase[](len);
        for (uint256 i = 0; i < len; ++i) {
            string memory key = string.concat(".addresses.strategyAddresses[", cheats.toString(i), "]");
            deployedStrategies[i] = StrategyBase(abi.decode(json.parseRaw(key), (address)));
        }
    }

    function parseDeployedEigenPods(
        string memory json
    ) internal pure returns (DeployedEigenPods memory) {
        require(json.parseUint(".chainInfo.chainId") == block.chainid, "wrong chain");
        return DeployedEigenPods(
            json.parseAddressArray(".eigenPods.multiValidatorPods"),
            json.parseAddressArray(".eigenPods.singleValidatorPods"),
            json.parseAddressArray(".eigenPods.inActivePods")
        );
    }

    function parseStrategiesToDeploy(
        string memory json
    ) internal pure returns (StrategyUnderlyingTokenConfig[] memory strategiesToDeploy) {
        uint256 len = json.parseUint(".strategies.numStrategies");
        strategiesToDeploy = new StrategyUnderlyingTokenConfig[](len);
        for (uint256 i = 0; i < len; ++i) {
            string memory key = string.concat(".strategies.strategiesToDeploy[", cheats.toString(i), "]");
            strategiesToDeploy[i] = abi.decode(stdJson.parseRaw(json, key), (StrategyUnderlyingTokenConfig));
        }
    }

    function parseDeployedContracts(
        string memory json
    ) internal returns (EigenLayer memory) {
        /// forgefmt: disable-next-item
        return EigenLayer({
            executorMultisig: json.parseAddress(".parameters.executorMultisig"),
            operationsMultisig: json.parseAddress(".parameters.operationsMultisig"),
            communityMultisig: json.parseAddress(".parameters.communityMultisig"),
            pauserMultisig: json.parseAddress(".parameters.pauserMultisig"),
            timelock: json.parseAddress(".parameters.timelock"),
            proxyAdmin: ProxyAdmin(json.parseAddress(".addresses.eigenLayerProxyAdmin")),
            tokenProxyAdmin: ProxyAdmin(json.parseAddress(".addresses.token.tokenProxyAdmin")),
            pauserRegistry: PauserRegistry(json.parseAddress(".addresses.eigenLayerPauserReg")),
            eigenPodBeacon: UpgradeableBeacon(json.parseAddress(".addresses.eigenPodBeacon")),
            strategyBeacon: UpgradeableBeacon(json.parseAddress(".addresses.strategyFactoryBeacon")),
            allocationManager: AllocationManager(json.parseAddress(".addresses.allocationManager")),
            allocationManagerImpl: AllocationManager(json.parseAddress(".addresses.allocationManagerImpl")),
            avsDirectory: AVSDirectory(json.parseAddress(".addresses.avsDirectory")),
            avsDirectoryImpl: AVSDirectory(json.parseAddress(".addresses.avsDirectoryImpl")),
            delegationManager: DelegationManager(json.parseAddress(".addresses.delegationManager")),
            delegationManagerImpl: DelegationManager(json.parseAddress(".addresses.delegationManagerImpl")),
            eigenPodManager: EigenPodManager(json.parseAddress(".addresses.eigenPodManager")),
            eigenPodManagerImpl: EigenPodManager(json.parseAddress(".addresses.eigenPodManagerImpl")),
            eigenPodImpl: EigenPod(payable(json.parseAddress(".addresses.eigenPodImpl"))),
            permissionController: PermissionController(json.parseAddress(".addresses.permissionController")),
            permissionControllerImpl: PermissionController(json.parseAddress(".addresses.permissionControllerImpl")),
            rewardsCoordinator: RewardsCoordinator(json.parseAddress(".addresses.rewardsCoordinator")),
            rewardsCoordinatorImpl: RewardsCoordinator(json.parseAddress(".addresses.rewardsCoordinatorImpl")),
            strategyManager: StrategyManager(json.parseAddress(".addresses.strategyManager")),
            strategyManagerImpl: StrategyManager(json.parseAddress(".addresses.strategyManagerImpl")),
            strategyFactory: StrategyFactory(json.parseAddress(".addresses.strategyFactory")),
            strategyFactoryImpl: StrategyFactory(json.parseAddress(".addresses.strategyFactoryImpl")),
            baseStrategyImpl: StrategyBase(json.parseAddress(".addresses.baseStrategyImpl")),
            strategyFactoryBeaconImpl: StrategyBase(json.parseAddress(".addresses.strategyFactoryBeaconImpl")),
            EIGEN: IEigen(json.parseAddress(".addresses.token.EIGEN")),
            EIGENImpl: IEigen(json.parseAddress(".addresses.token.EIGENImpl")),
            bEIGEN: IBackingEigen(json.parseAddress(".addresses.token.bEIGEN")),
            bEIGENImpl: IBackingEigen(json.parseAddress(".addresses.token.bEIGENImpl")),
            eigenStrategy: EigenStrategy(json.parseAddress(".addresses.token.eigenStrategy")),
            eigenStrategyImpl: EigenStrategy(json.parseAddress(".addresses.token.eigenStrategyImpl")),
            emptyContract: EmptyContract(json.parseAddress(".addresses.emptyContract")),
            deployedEigenPods: json.parseDeployedEigenPods(),
            deployedStrategies: json.parseDeployedStrategies(),
            strategiesToDeploy: json.parseStrategiesToDeploy()
        })
            .checkNonZero()
            .checkPointers()
            .checkInitialized()
            .checkImpls();
    }

    /// -----------------------------------------------------------------------
    /// Checks
    /// -----------------------------------------------------------------------

    /// @dev Asserts that all parsed addresses are non-zero.
    function checkNonZero(
        EigenLayer memory eigenLayer
    ) internal view returns (EigenLayer memory) {
        // Administration
        require(eigenLayer.executorMultisig != address(0), "executorMultisig is zero");
        require(eigenLayer.operationsMultisig != address(0), "operationsMultisig is zero");
        require(eigenLayer.communityMultisig != address(0), "communityMultisig is zero");
        require(eigenLayer.pauserMultisig != address(0), "pauserMultisig is zero");
        require(eigenLayer.timelock != address(0), "timelock is zero");
        require(address(eigenLayer.proxyAdmin) != address(0), "proxyAdmin is zero");
        require(address(eigenLayer.tokenProxyAdmin) != address(0), "tokenProxyAdmin is zero");
        require(address(eigenLayer.pauserRegistry) != address(0), "pauserRegistry is zero");
        require(address(eigenLayer.eigenPodBeacon) != address(0), "eigenPodBeacon is zero");
        require(address(eigenLayer.strategyBeacon) != address(0), "strategyBeacon is zero");
        // Core
        require(address(eigenLayer.allocationManager) != address(0), "allocationManager is zero");
        require(address(eigenLayer.allocationManagerImpl) != address(0), "allocationManagerImpl is zero");
        require(address(eigenLayer.avsDirectory) != address(0), "avsDirectory is zero");
        require(address(eigenLayer.avsDirectoryImpl) != address(0), "avsDirectoryImpl is zero");
        require(address(eigenLayer.delegationManager) != address(0), "delegationManager is zero");
        require(address(eigenLayer.delegationManagerImpl) != address(0), "delegationManagerImpl is zero");
        require(address(eigenLayer.eigenPodManager) != address(0), "eigenPodManager is zero");
        require(address(eigenLayer.eigenPodManagerImpl) != address(0), "eigenPodManagerImpl is zero");
        require(address(eigenLayer.eigenPodImpl) != address(0), "eigenPodImpl is zero");
        require(address(eigenLayer.permissionController) != address(0), "permissionController is zero");
        require(address(eigenLayer.permissionControllerImpl) != address(0), "permissionControllerImpl is zero");
        require(address(eigenLayer.rewardsCoordinator) != address(0), "rewardsCoordinator is zero");
        require(address(eigenLayer.rewardsCoordinatorImpl) != address(0), "rewardsCoordinatorImpl is zero");
        require(address(eigenLayer.strategyManager) != address(0), "strategyManager is zero");
        require(address(eigenLayer.strategyManagerImpl) != address(0), "strategyManagerImpl is zero");
        require(address(eigenLayer.strategyFactory) != address(0), "strategyFactory is zero");
        require(address(eigenLayer.strategyFactoryImpl) != address(0), "strategyFactoryImpl is zero");
        require(address(eigenLayer.baseStrategyImpl) != address(0), "baseStrategyImpl is zero");
        require(address(eigenLayer.strategyFactoryBeaconImpl) != address(0), "strategyFactoryBeaconImpl is zero");
        // Token
        require(address(eigenLayer.EIGEN) != address(0), "EIGEN is zero");
        require(address(eigenLayer.EIGENImpl) != address(0), "EIGENImpl is zero");
        require(address(eigenLayer.bEIGEN) != address(0), "bEIGEN is zero");
        require(address(eigenLayer.bEIGENImpl) != address(0), "bEIGENImpl is zero");
        require(address(eigenLayer.eigenStrategy) != address(0), "eigenStrategy is zero");
        require(address(eigenLayer.eigenStrategyImpl) != address(0), "eigenStrategyImpl is zero");
        // Utils
        require(address(eigenLayer.emptyContract) != address(0), "emptyContract is zero");

        for (uint256 i = 0; i < eigenLayer.deployedEigenPods.multiValidatorPods.length; ++i) {
            require(eigenLayer.deployedEigenPods.multiValidatorPods[i] != address(0), "multiValidatorPods is zero");
        }

        for (uint256 i = 0; i < eigenLayer.deployedEigenPods.singleValidatorPods.length; ++i) {
            require(eigenLayer.deployedEigenPods.singleValidatorPods[i] != address(0), "singleValidatorPods is zero");
        }

        for (uint256 i = 0; i < eigenLayer.deployedEigenPods.inActivePods.length; ++i) {
            require(eigenLayer.deployedEigenPods.inActivePods[i] != address(0), "inActivePods is zero");
        }

        for (uint256 i = 0; i < eigenLayer.deployedStrategies.length; ++i) {
            require(eigenLayer.deployedStrategies[i] != address(0), "deployedStrategies is zero");
        }

        for (uint256 i = 0; i < eigenLayer.strategiesToDeploy.length; ++i) {
            require(eigenLayer.strategiesToDeploy[i].tokenAddress != address(0), "strategiesToDeploy is zero");
        }

        return eigenLayer;
    }

    function checkPointers(
        EigenLayer memory eigenLayer
    ) internal view returns (EigenLayer memory) {
        // AVSDirectory
        require(
            eigenLayer.avsDirectory.delegation() == eigenLayer.delegationManager,
            "avsDirectory: delegationManager address not set correctly"
        );
        // RewardsCoordinator
        require(
            eigenLayer.rewardsCoordinator.delegationManager() == eigenLayer.delegationManager,
            "rewardsCoordinator: delegationManager address not set correctly"
        );
        require(
            eigenLayer.rewardsCoordinator.strategyManager() == eigenLayer.strategyManager,
            "rewardsCoordinator: strategyManager address not set correctly"
        );
        // DelegationManager
        require(
            eigenLayer.delegationManager.strategyManager() == eigenLayer.strategyManager,
            "delegationManager: strategyManager address not set correctly"
        );
        require(
            eigenLayer.delegationManager.eigenPodManager() == eigenLayer.eigenPodManager,
            "delegationManager: eigenPodManager address not set correctly"
        );
        // StrategyManager
        require(
            eigenLayer.strategyManager.delegation() == eigenLayer.delegationManager,
            "strategyManager: delegationManager address not set correctly"
        );
        // EPM
        require(
            address(eigenLayer.eigenPodManager.ethPOS()) == eigenLayer.ETHPOSDepositAddress,
            "eigenPodManager: ethPOSDeposit contract address not set correctly"
        );
        require(
            eigenLayer.eigenPodManager.eigenPodBeacon() == eigenLayer.eigenPodBeacon,
            "eigenPodManager: eigenPodBeacon contract address not set correctly"
        );
        require(
            eigenLayer.eigenPodManager.delegationManager() == eigenLayer.delegationManager,
            "eigenPodManager: delegationManager contract address not set correctly"
        );

        for (uint256 i = 0; i < eigenLayer.deployedStrategies.length; ++i) {
            require(
                eigenLayer.eigenLayerProxyAdmin.getProxyImpl(
                    ITransparentUpgradeableProxy(payable(address(eigenLayer.deployedStrategies[i])))
                ) == address(eigenLayer.baseStrategyImpl),
                "strategy: implementation set incorrectly"
            );
        }

        require(
            eigenLayer.eigenPodBeacon.implementation() == address(eigenLayer.eigenPodImpl),
            "eigenPodBeacon: implementation set incorrectly"
        );

        return eigenLayer;
    }

    function checkInitialized(
        EigenLayer memory eigenLayer
    ) internal view returns (EigenLayer memory) {
        // AVSDirectory
        cheats.expectRevert("Initializable: contract is already initialized");
        eigenLayer.avsDirectory.initialize(address(0), AVS_DIRECTORY_INIT_PAUSED_STATUS);
        // RewardsCoordinator
        cheats.expectRevert("Initializable: contract is already initialized");
        eigenLayer.rewardsCoordinator.initialize(address(0), 0, address(0), 0, 0);
        // DelegationManager
        cheats.expectRevert("Initializable: contract is already initialized");
        eigenLayer.delegationManager.initialize(address(0), 0);
        // StrategyManager
        cheats.expectRevert("Initializable: contract is already initialized");
        eigenLayer.strategyManager.initialize(address(0), address(0), STRATEGY_MANAGER_INIT_PAUSED_STATUS);
        // EigenPodManager
        cheats.expectRevert("Initializable: contract is already initialized");
        eigenLayer.eigenPodManager.initialize(address(0), EIGENPOD_MANAGER_INIT_PAUSED_STATUS);
        // Strategies
        for (uint256 i = 0; i < eigenLayer.deployedStrategies.length; ++i) {
            cheats.expectRevert("Initializable: contract is already initialized");
            StrategyBaseTVLLimits(address(eigenLayer.deployedStrategies[i])).initialize(0, 0, IERC20(address(0)));
        }
        return eigenLayer;
    }

    function checkImpls(
        EigenLayer memory eigenLayer
    ) internal view {
        assertEq(
            eigenLayer.proxyAdmin.getProxyImpl(ITransparentUpgradeableProxy(payable(address(eigenLayer.avsDirectory)))),
            address(eigenLayer.avsDirectoryImpl),
            "avsDirectory: implementation set incorrectly"
        );
        assertEq(
            eigenLayer.proxyAdmin.getProxyImpl(
                ITransparentUpgradeableProxy(payable(address(eigenLayer.rewardsCoordinator)))
            ),
            address(eigenLayer.rewardsCoordinatorImpl),
            "rewardsCoordinator: implementation set incorrectly"
        );
        assertEq(
            eigenLayer.proxyAdmin.getProxyImpl(
                ITransparentUpgradeableProxy(payable(address(eigenLayer.delegationManager)))
            ),
            address(eigenLayer.delegationManagerImpl),
            "delegationManager: implementation set incorrectly"
        );
        assertEq(
            eigenLayer.proxyAdmin.getProxyImpl(
                ITransparentUpgradeableProxy(payable(address(eigenLayer.strategyManager)))
            ),
            address(eigenLayer.strategyManagerImpl),
            "strategyManager: implementation set incorrectly"
        );
        assertEq(
            eigenLayer.proxyAdmin.getProxyImpl(
                ITransparentUpgradeableProxy(payable(address(eigenLayer.eigenPodManager)))
            ),
            address(eigenLayer.eigenPodManagerImpl),
            "eigenPodManager: implementation set incorrectly"
        );

        for (uint256 i = 0; i < eigenLayer.deployedStrategies.length; ++i) {
            assertEq(
                eigenLayer.proxyAdmin.getProxyImpl(
                    ITransparentUpgradeableProxy(payable(address(eigenLayer.deployedStrategies[i])))
                ),
                address(eigenLayer.baseStrategyImpl),
                "strategy: implementation set incorrectly"
            );
        }

        assertEq(
            eigenLayer.eigenPodBeacon.implementation(),
            address(eigenLayer.eigenPodImpl),
            "eigenPodBeacon: implementation set incorrectly"
        );

        return eigenLayer;
    }
}

contract ExistingDeploymentParser is Script, Logger {
    using stdJson for string;

    EigenLayer public eigenLayer;

    /// -----------------------------------------------------------------------
    ///
    /// -----------------------------------------------------------------------

    function NAME() public view virtual override returns (string memory) {
        return "ExistingDeploymentParser";
    }

    // /// @notice use for deploying a new set of EigenLayer contracts
    // /// Note that this does assertEq multisigs to already be deployed
    // function _parseInitialDeploymentParams(
    //     string memory initialDeploymentParamsPath
    // ) internal virtual {
    //     // read and log the chainID
    //     uint256 currentChainId = block.chainid;
    //     console.log("You are parsing on ChainID", currentChainId);

    //     // READ JSON CONFIG DATA
    //     string memory json = cheats.readFile(initialDeploymentParamsPath);

    //     // check that the chainID matches the one in the config
    //     uint256 configChainId = json.readUint(".chainInfo.chainId");
    //     assertEq(configChainId, currentChainId, "You are on the wrong chain for this config");

    //     console.log("Using config file", initialDeploymentParamsPath);
    //     console.log("- Last Updated", stdJson.readString(json, ".lastUpdated"));

    //     // read all of the deployed addresses
    //     executorMultisig = json.readAddress(".multisig_addresses.executorMultisig");
    //     operationsMultisig = json.readAddress(".multisig_addresses.operationsMultisig");
    //     communityMultisig = json.readAddress(".multisig_addresses.communityMultisig");
    //     pauserMultisig = json.readAddress(".multisig_addresses.pauserMultisig");

    //     // Strategies to Deploy, load strategy list
    //     numStrategiesToDeploy = json.readUint(".strategies.numStrategies");
    //     STRATEGY_MAX_PER_DEPOSIT = json.readUint(".strategies.MAX_PER_DEPOSIT");
    //     STRATEGY_MAX_TOTAL_DEPOSITS = json.readUint(".strategies.MAX_TOTAL_DEPOSITS");
    //     for (uint256 i = 0; i < numStrategiesToDeploy; ++i) {
    //         // Form the key for the current element
    //         string memory key = string.concat(".strategies.strategiesToDeploy[", cheats.toString(i), "]");

    //         // Use parseJson with the key to get the value for the current element
    //         bytes memory tokenInfoBytes = stdJson.parseRaw(json, key);

    //         // Decode the token information into the Token struct
    //         StrategyUnderlyingTokenConfig memory tokenInfo = abi.decode(tokenInfoBytes, (StrategyUnderlyingTokenConfig));

    //         strategiesToDeploy.push(tokenInfo);
    //     }

    //     // Read initialize params for upgradeable contracts
    //     STRATEGY_MANAGER_INIT_PAUSED_STATUS = json.readUint(".strategyManager.init_paused_status");
    //     STRATEGY_MANAGER_WHITELISTER = json.readAddress(".strategyManager.init_strategy_whitelister");
    //     // DelegationManager
    //     DELEGATION_MANAGER_MIN_WITHDRAWAL_DELAY_BLOCKS = uint32(json.readUint(".delegationManager.init_minWithdrawalDelayBlocks"));
    //     DELEGATION_MANAGER_INIT_PAUSED_STATUS = json.readUint(".delegationManager.init_paused_status");
    //     // RewardsCoordinator

    //     REWARDS_COORDINATOR_INIT_PAUSED_STATUS = json.readUint(".rewardsCoordinator.init_paused_status");
    //     REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS = uint32(json.readUint(".rewardsCoordinator.CALCULATION_INTERVAL_SECONDS"));
    //     REWARDS_COORDINATOR_MAX_REWARDS_DURATION = uint32(json.readUint(".rewardsCoordinator.MAX_REWARDS_DURATION"));
    //     REWARDS_COORDINATOR_MAX_RETROACTIVE_LENGTH = uint32(json.readUint(".rewardsCoordinator.MAX_RETROACTIVE_LENGTH"));
    //     REWARDS_COORDINATOR_MAX_FUTURE_LENGTH = uint32(json.readUint(".rewardsCoordinator.MAX_FUTURE_LENGTH"));
    //     REWARDS_COORDINATOR_GENESIS_REWARDS_TIMESTAMP = uint32(json.readUint(".rewardsCoordinator.GENESIS_REWARDS_TIMESTAMP"));
    //     REWARDS_COORDINATOR_UPDATER = json.readAddress(".rewardsCoordinator.rewards_updater_address");
    //     REWARDS_COORDINATOR_ACTIVATION_DELAY = uint32(json.readUint(".rewardsCoordinator.activation_delay"));
    //     REWARDS_COORDINATOR_DEFAULT_OPERATOR_SPLIT_BIPS = uint32(json.readUint(".rewardsCoordinator.default_operator_split_bips"));
    //     REWARDS_COORDINATOR_OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP =
    //         uint32(json.readUint(".rewardsCoordinator.OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP"));
    //     REWARDS_COORDINATOR_OPERATOR_SET_MAX_RETROACTIVE_LENGTH = uint32(json.readUint(".rewardsCoordinator.OPERATOR_SET_MAX_RETROACTIVE_LENGTH"));
    //     // AVSDirectory
    //     AVS_DIRECTORY_INIT_PAUSED_STATUS = json.readUint(".avsDirectory.init_paused_status");
    //     // EigenPodManager
    //     EIGENPOD_MANAGER_INIT_PAUSED_STATUS = json.readUint(".eigenPodManager.init_paused_status");
    //     // AllocationManager
    //     ALLOCATION_MANAGER_INIT_PAUSED_STATUS = json.readUint(".allocationManager.init_paused_status");
    //     // EigenPod
    //     EIGENPOD_GENESIS_TIME = uint64(json.readUint(".eigenPod.GENESIS_TIME"));
    //     ETHPOSDepositAddress = json.readAddress(".ethPOSDepositAddress");

    //     // check that all values are non-zero
    //     logInitialDeploymentParams();
    // }

    // /// @notice Verify params based on config constants that are updated from calling `_parseInitialDeploymentParams`
    // function _verifyInitializationParams() internal view virtual {
    //     // AVSDirectory
    //     assertTrue(avsDirectory.pauserRegistry() == eigenLayerPauserReg, "avsdirectory: pauser registry not set correctly");
    //     assertEq(avsDirectory.owner(), executorMultisig, "avsdirectory: owner not set correctly");
    //     assertEq(avsDirectory.paused(), AVS_DIRECTORY_INIT_PAUSED_STATUS, "avsdirectory: init paused status set incorrectly");
    //     // RewardsCoordinator
    //     assertTrue(rewardsCoordinator.pauserRegistry() == eigenLayerPauserReg, "rewardsCoordinator: pauser registry not set correctly");
    //     // assertEq(
    //     //     rewardsCoordinator.owner(), executorMultisig,
    //     //     "rewardsCoordinator: owner not set correctly"
    //     // );
    //     // assertEq(
    //     //     rewardsCoordinator.paused(), REWARDS_COORDINATOR_INIT_PAUSED_STATUS,
    //     //     "rewardsCoordinator: init paused status set incorrectly"
    //     // );
    //     assertEq(
    //         rewardsCoordinator.MAX_REWARDS_DURATION(),
    //         REWARDS_COORDINATOR_MAX_REWARDS_DURATION,
    //         "rewardsCoordinator: maxRewardsDuration not set correctly"
    //     );
    //     assertEq(
    //         rewardsCoordinator.MAX_RETROACTIVE_LENGTH(),
    //         REWARDS_COORDINATOR_MAX_RETROACTIVE_LENGTH,
    //         "rewardsCoordinator: maxRetroactiveLength not set correctly"
    //     );
    //     assertEq(
    //         rewardsCoordinator.MAX_FUTURE_LENGTH(), REWARDS_COORDINATOR_MAX_FUTURE_LENGTH, "rewardsCoordinator: maxFutureLength not set correctly"
    //     );
    //     assertEq(
    //         rewardsCoordinator.GENESIS_REWARDS_TIMESTAMP(),
    //         REWARDS_COORDINATOR_GENESIS_REWARDS_TIMESTAMP,
    //         "rewardsCoordinator: genesisRewardsTimestamp not set correctly"
    //     );
    //     // assertEq(
    //     //     rewardsCoordinator.rewardsUpdater(), REWARDS_COORDINATOR_UPDATER,
    //     //     "rewardsCoordinator: rewardsUpdater not set correctly"
    //     // );
    //     assertEq(rewardsCoordinator.activationDelay(), REWARDS_COORDINATOR_ACTIVATION_DELAY, "rewardsCoordinator: activationDelay not set correctly");
    //     assertEq(
    //         rewardsCoordinator.CALCULATION_INTERVAL_SECONDS(),
    //         REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS,
    //         "rewardsCoordinator: CALCULATION_INTERVAL_SECONDS not set correctly"
    //     );
    //     assertEq(
    //         rewardsCoordinator.defaultOperatorSplitBips(),
    //         REWARDS_COORDINATOR_DEFAULT_OPERATOR_SPLIT_BIPS,
    //         "rewardsCoordinator: defaultSplitBips not set correctly"
    //     );
    //     // DelegationManager
    //     assertTrue(delegationManager.pauserRegistry() == eigenLayerPauserReg, "delegationManager: pauser registry not set correctly");
    //     assertEq(delegationManager.owner(), executorMultisig, "delegationManager: owner not set correctly");
    //     assertEq(delegationManager.paused(), DELEGATION_MANAGER_INIT_PAUSED_STATUS, "delegationManager: init paused status set incorrectly");
    //     // StrategyManager
    //     assertTrue(strategyManager.pauserRegistry() == eigenLayerPauserReg, "strategyManager: pauser registry not set correctly");
    //     assertEq(strategyManager.owner(), executorMultisig, "strategyManager: owner not set correctly");
    //     assertEq(strategyManager.paused(), STRATEGY_MANAGER_INIT_PAUSED_STATUS, "strategyManager: init paused status set incorrectly");
    //     if (block.chainid == 1) {
    //         assertEq(strategyManager.strategyWhitelister(), address(strategyFactory), "strategyManager: strategyWhitelister not set correctly");
    //     } else if (block.chainid == 17_000) {
    //         // On holesky, for ease of whitelisting we set to executorMultisig
    //         // assertEq(
    //         //     strategyManager.strategyWhitelister(), executorMultisig,
    //         //     "strategyManager: strategyWhitelister not set correctly"
    //         // );
    //     }
    //     // EigenPodManager
    //     assertTrue(eigenPodManager.pauserRegistry() == eigenLayerPauserReg, "eigenPodManager: pauser registry not set correctly");
    //     assertEq(eigenPodManager.owner(), executorMultisig, "eigenPodManager: owner not set correctly");
    //     assertEq(eigenPodManager.paused(), EIGENPOD_MANAGER_INIT_PAUSED_STATUS, "eigenPodManager: init paused status set incorrectly");
    //     assertEq(address(eigenPodManager.ethPOS()), address(ETHPOSDepositAddress), "eigenPodManager: ethPOS not set correctly");
    //     // EigenPodBeacon
    //     assertEq(eigenPodBeacon.owner(), executorMultisig, "eigenPodBeacon: owner not set correctly");
    //     // EigenPodImplementation
    //     assertEq(eigenPodImplementation.GENESIS_TIME(), EIGENPOD_GENESIS_TIME, "eigenPodImplementation: GENESIS TIME not set correctly");
    //     assertEq(address(eigenPodImplementation.ethPOS()), ETHPOSDepositAddress, "eigenPodImplementation: ethPOS not set correctly");
    //     // Strategies
    //     for (uint256 i = 0; i < deployedStrategyArray.length; ++i) {
    //         assertTrue(deployedStrategyArray[i].pauserRegistry() == eigenLayerPauserReg, "StrategyBaseTVLLimits: pauser registry not set correctly");
    //         assertEq(deployedStrategyArray[i].paused(), 0, "StrategyBaseTVLLimits: init paused status set incorrectly");
    //         assertTrue(
    //             strategyManager.strategyIsWhitelistedForDeposit(deployedStrategyArray[i]), "StrategyBaseTVLLimits: strategy should be whitelisted"
    //         );
    //     }

    //     // Pausing Permissions
    //     assertTrue(eigenLayerPauserReg.isPauser(operationsMultisig), "pauserRegistry: operationsMultisig is not pauser");
    //     assertTrue(eigenLayerPauserReg.isPauser(executorMultisig), "pauserRegistry: executorMultisig is not pauser");
    //     assertTrue(eigenLayerPauserReg.isPauser(pauserMultisig), "pauserRegistry: pauserMultisig is not pauser");
    //     assertEq(eigenLayerPauserReg.unpauser(), executorMultisig, "pauserRegistry: unpauser not set correctly");
    // }

    // /// @notice used for parsing parameters used in the integration test upgrade
    // function _parseParamsForIntegrationUpgrade(
    //     string memory initialDeploymentParamsPath
    // ) internal virtual {
    //     // read and log the chainID
    //     uint256 currentChainId = block.chainid;
    //     console.log("You are parsing on ChainID", currentChainId);

    //     // READ JSON CONFIG DATA
    //     string memory json = cheats.readFile(initialDeploymentParamsPath);

    //     // check that the chainID matches the one in the config
    //     uint256 configChainId = _readUint(json, ".config.environment.chainid");
    //     assertEq(configChainId, currentChainId, "You are on the wrong chain for this config");

    //     console.log("Using config file", initialDeploymentParamsPath);
    //     console.log("- Last Updated", stdJson.readString(json, ".config.environment.lastUpdated"));

    //     REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS = uint32(_readUint(json, ".config.params.CALCULATION_INTERVAL_SECONDS"));
    //     REWARDS_COORDINATOR_MAX_REWARDS_DURATION = uint32(_readUint(json, ".config.params.MAX_REWARDS_DURATION"));
    //     REWARDS_COORDINATOR_MAX_RETROACTIVE_LENGTH = uint32(_readUint(json, ".config.params.MAX_RETROACTIVE_LENGTH"));
    //     REWARDS_COORDINATOR_MAX_FUTURE_LENGTH = uint32(_readUint(json, ".config.params.MAX_FUTURE_LENGTH"));
    //     REWARDS_COORDINATOR_GENESIS_REWARDS_TIMESTAMP = uint32(_readUint(json, ".config.params.GENESIS_REWARDS_TIMESTAMP"));
    // }
}
