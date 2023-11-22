// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import {
    RhinestoneModuleKit,
    RhinestoneModuleKitLib,
    RhinestoneAccount
} from "modulekit/test/utils/biconomy-base/RhinestoneModuleKit.sol";
import { SplitInvestorModule } from "../../src/executors/SplitInvestorModule.sol";
import { MockToken } from "@src/test/MockToken.sol";
import { Swapper } from "@src/test/Swapper.sol";

import "forge-std/console.sol";
contract SplitInvestorModuleTest is Test, RhinestoneModuleKit {
    using RhinestoneModuleKitLib for RhinestoneAccount;

    RhinestoneAccount instance;
    SplitInvestorModule splitInvestorModule;
    MockToken fundingToken;
    MockToken btc;
    MockToken steth;
    Swapper swapper;
    address owner = makeAddr("owner");
    function setUp() public {
        // Setup account
        instance = makeRhinestoneAccount("1");
        vm.deal(instance.account, 10 ether);
        fundingToken = new MockToken();
        btc = new MockToken();
        steth = new MockToken();
        fundingToken.mint(owner, 100 ether);
        swapper = new Swapper(address(fundingToken), address(btc), address(steth));
        // Setup executor
        splitInvestorModule = new SplitInvestorModule(makeAddr("CLRouter"), address(fundingToken), address(swapper));

        // Add executor to account
        instance.addExecutor(address(splitInvestorModule));
    }

    function testDepositAndInvestBalanceCorrect() public {
        // Create target and ensure that it doesnt have a balance
        assertEq(fundingToken.balanceOf(address(splitInvestorModule)), 0);

        vm.startPrank(owner);
        fundingToken.approve(instance.account, 1 ether);
        splitInvestorModule.depositAndInvest(instance.account, 1 ether, abi.encode(instance.aux.executorManager));
        vm.stopPrank();

        assertEq(fundingToken.balanceOf(instance.account), 1 ether);
    }

    function testSetAllocationTooHigh() public {
        SplitInvestorModule.Allocation[] memory allocation = new SplitInvestorModule.Allocation[](2);
        address[] memory allocationList = new address[](2);
        allocationList[0] = address(btc);
        allocationList[1] = address(steth);
        allocation[0] = SplitInvestorModule.Allocation(5_000, 0);
        allocation[1] = SplitInvestorModule.Allocation(5_100, 0);
        
        vm.expectRevert();
        splitInvestorModule.setAllocation(allocationList, allocation);
    }

    function testSetAllocationHappy() public {
        address[] memory allocationList = new address[](2);
        allocationList[0] = address(btc);
        allocationList[1] = address(steth);
        SplitInvestorModule.Allocation[] memory allocation = new SplitInvestorModule.Allocation[](2);
        allocation[0] = SplitInvestorModule.Allocation(5_000, 0);
        allocation[1] = SplitInvestorModule.Allocation(4_000, 0);
        
        splitInvestorModule.setAllocation(allocationList, allocation);
        assertEq(splitInvestorModule.allocationEnumeratedLength(), 2);

        assertEq(splitInvestorModule.allocationPercentage(address(btc)), 5_000);
        assertEq(splitInvestorModule.allocationPercentage(address(steth)), 4_000);
    }

    function testSetCalculateRebalance() public {
        assertEq(splitInvestorModule.calculateRebalance(), bytes8(abi.encodePacked(bytes1(0x51))));
    }


    function testDepositAndInvestWithAllocation() public {
        // Create target and ensure that it doesnt have a balance
        assertEq(fundingToken.balanceOf(address(splitInvestorModule)), 0);

        // Allocate
        address[] memory allocationList = new address[](2);
        allocationList[0] = address(btc);
        allocationList[1] = address(steth);
        SplitInvestorModule.Allocation[] memory allocation = new SplitInvestorModule.Allocation[](2);
        allocation[0] = SplitInvestorModule.Allocation(6_000, 0);
        allocation[1] = SplitInvestorModule.Allocation(4_000, 0);
        
        splitInvestorModule.setAllocation(allocationList, allocation);

        // Check notional value for each token before
        assertEq(splitInvestorModule.allocationNotionalValue(address(btc)), 0);
        assertEq(splitInvestorModule.allocationNotionalValue(address(steth)), 0);

        vm.startPrank(owner);
        fundingToken.approve(instance.account, 2 ether);
        splitInvestorModule.depositAndInvest(instance.account, 1 ether, abi.encode(instance.aux.executorManager));
        vm.stopPrank();

        // Should have the correct balance of btc and steth
        assertEq(fundingToken.balanceOf(instance.account), 0);
        assertEq(btc.balanceOf(instance.account), 0.60 ether);
        assertEq(steth.balanceOf(instance.account), 0.40 ether);
        
        // Check notional value for each token
        assertEq(splitInvestorModule.allocationNotionalValue(address(btc)), 0.60 ether);
        assertEq(splitInvestorModule.allocationNotionalValue(address(steth)), 0.40 ether);
    }
}
