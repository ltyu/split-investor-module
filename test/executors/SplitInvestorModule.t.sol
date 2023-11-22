// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import {
    RhinestoneModuleKit,
    RhinestoneModuleKitLib,
    RhinestoneAccount
} from "modulekit/test/utils/biconomy-base/RhinestoneModuleKit.sol";
import { SplitInvestorModule } from "../../src/executors/SplitInvestorModule.sol";
import "forge-std/console.sol";
contract SplitInvestorModuleTest is Test, RhinestoneModuleKit {
    using RhinestoneModuleKitLib for RhinestoneAccount;

    RhinestoneAccount instance;
    SplitInvestorModule splitInvestorModule;
    address btc = makeAddr("btc");
    address steth = makeAddr("steth");

    function setUp() public {
        // Setup account
        instance = makeRhinestoneAccount("1");
        vm.deal(instance.account, 10 ether);

        // Setup executor
        splitInvestorModule = new SplitInvestorModule(makeAddr("CLRouter"));

        // Add executor to account
        instance.addExecutor(address(splitInvestorModule));
    }

    function testDepositAndInvest() public {
        // Create target and ensure that it doesnt have a balance
        address target = makeAddr("target");
        assertEq(target.balance, 0);

        // Execute action from target using vm.prank()
        vm.prank(target);
        splitInvestorModule.depositAndInvest(instance.account, abi.encode(instance.aux.executorManager));

        // Assert that target has a balance of 1 wei
        assertEq(target.balance, 1 wei);
    }

    function testSetAllocationTooHigh() public {
        SplitInvestorModule.Allocation[] memory allocation = new SplitInvestorModule.Allocation[](2);
        allocation[0] = SplitInvestorModule.Allocation(btc, 5_000, 0);
        allocation[1] = SplitInvestorModule.Allocation(steth, 5_100, 0);
        
        vm.expectRevert();
        splitInvestorModule.setAllocation(allocation);
    }

    function testSetAllocationHappy() public {
        SplitInvestorModule.Allocation[] memory allocation = new SplitInvestorModule.Allocation[](2);
        allocation[0] = SplitInvestorModule.Allocation(btc, 5_000, 0);
        allocation[1] = SplitInvestorModule.Allocation(steth, 4_000, 0);
        
        splitInvestorModule.setAllocation(allocation);
        assertEq(splitInvestorModule.allocationEnumeratedLength(), 2);
        assertEq(splitInvestorModule.allocationPercentages(btc), 5_000);
        assertEq(splitInvestorModule.allocationPercentages(steth), 4_000);
    }

    function testSetCalculateRebalance() public {
        assertEq(splitInvestorModule.calculateRebalance(), bytes8(abi.encodePacked(bytes1(0x51))));
    }
}
