// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "./DummyRegistrar.sol";

contract Deploy_Registrar is Script {
    DummyRegistrar registrar;

    function run() public {
        vm.startBroadcast();
        registrar = new DummyRegistrar();
        vm.stopBroadcast();
    }
}