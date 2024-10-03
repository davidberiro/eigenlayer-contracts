// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "script/Release_Template.s.sol";
import {IUpgradeableBeacon} from "script/utils/Interfaces.sol";

library TxHelper {

    function append(
        Tx[] storage txs, 
        address to,
        uint value,
        bytes memory data
    ) internal returns (Tx[] storage) {
        txs.push(Tx({
            to: to,
            value: value,
            data: data
        }));

        return txs;
    }

    function append(
        Tx[] storage txs, 
        address to,
        bytes memory data
    ) internal returns (Tx[] storage) {
        txs.push(Tx({
            to: to,
            value: 0,
            data: data
        }));

        return txs;
    }
}

contract UpgradeCounter is MultisigBuilder {

    using TxHelper for *;

    Tx[] txs;

    function _execute(Addresses memory addrs, Environment memory env, Params memory params) internal override returns (Tx[] memory) {
        txs.append({
            to: addrs.admin.timelock,
            data: abi.encodeWithSelector(
                ITimelock.executeTransaction.selector(
                    to, 
                    value, 
                    signature, 
                    data, 
                    eta
                )
            )
        });

        txs.append({
            to: addrs.proxyAdmin,
            data: abi.encodeWithSelector(
                ProxyAdmin.upgrade.selector,
                addrs.eigenPodManager,
                addrs.eigenPod.pendingImpl
            )
        });

        return txs;
    }

    function _test_Execute(
        Addresses memory addrs, 
        Environment memory env, 
        Params memory params
    ) internal override {
        bytes memory data = encodeMultisendTxs(arr);
        
        vm.startBroadcast(addrs.admin.opsMultisig);
        addrs.admin.multiSend.delegatecall(data);
        vm.stopBroadcast();


    }
}