// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import {
    RhinestoneModuleKit,
    RhinestoneModuleKitLib,
    RhinestoneAccount
} from "modulekit/test/utils/biconomy-base/RhinestoneModuleKit.sol";
import { SplitInvestorModule } from "../../src/executors/SplitInvestorModule.sol";

contract SplitInvestorModuleTest is Test, RhinestoneModuleKit {
    using RhinestoneModuleKitLib for RhinestoneAccount;

    RhinestoneAccount instance;
    SplitInvestorModule splitInvestorModule;

    function setUp() public {
        // Setup account
        instance = makeRhinestoneAccount("1");
        vm.deal(instance.account, 10 ether);

        // Setup executor
        splitInvestorModule = new SplitInvestorModule(makeAddr("CLRouter"));

        // Add executor to account
        instance.addExecutor(address(splitInvestorModule));
    }

    function testExecuteAction() public {
        // Create target and ensure that it doesnt have a balance
        address target = makeAddr("target");
        assertEq(target.balance, 0);

        // Execute action from target using vm.prank()
        vm.prank(target);
        splitInvestorModule.depositAndInvest(instance.account, abi.encode(instance.aux.executorManager));

        // Assert that target has a balance of 1 wei
        assertEq(target.balance, 1 wei);
    }
}
