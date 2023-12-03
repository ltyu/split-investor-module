// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import {
    RhinestoneModuleKit,
    RhinestoneModuleKitLib,
    RhinestoneAccount
} from "@modulekit/test/utils/biconomy-base/RhinestoneModuleKit.sol";
import { SplitInvestorModule } from "@src/executors/SplitInvestorModule.sol";
import { MockToken } from "@src/test/MockToken.sol";
import { Swapper } from "@src/test/Swapper.sol";
import { MockRouter } from "@src/test/MockRouter.sol";

import "forge-std/console.sol";
contract SplitInvestorModuleTest is Test, RhinestoneModuleKit {
    using Strings for address;
    using RhinestoneModuleKitLib for RhinestoneAccount;

    RhinestoneAccount instance;
    SplitInvestorModule splitInvestorModule;
    MockToken fundingToken;
    MockToken btc;
    MockToken steth;
    MockToken matic;
    Swapper swapper;
    address owner = makeAddr("owner");
    MockRouter chainlinkRouter;

    function setUp() public {
        // Setup account
        instance = makeRhinestoneAccount("1");
        vm.deal(instance.account, 10 ether);
        fundingToken = new MockToken();
        btc = new MockToken();
        steth = new MockToken();
        matic = new MockToken();
        fundingToken.mint(owner, 100 ether);
        swapper = new Swapper(address(fundingToken), address(btc), address(steth));
        chainlinkRouter = new MockRouter();
        // Setup executor
        splitInvestorModule = new SplitInvestorModule(address(chainlinkRouter), address(fundingToken), address(swapper));
        chainlinkRouter.setSplitModule(address(splitInvestorModule));

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


    function testCalculateRebalanceHappy() public {
        // Create target and ensure that it doesnt have a balance
        assertEq(fundingToken.balanceOf(address(splitInvestorModule)), 0);
        // Set prices
        splitInvestorModule.setTokenPrice(address(btc), 1 ether);
        splitInvestorModule.setTokenPrice(address(steth), 1 ether);
        splitInvestorModule.setTokenPrice(address(matic), 1 ether);
        
        // Allocate
        address[] memory allocationList = new address[](3);
        allocationList[0] = address(btc);
        allocationList[1] = address(steth);
        allocationList[2] = address(matic);
        SplitInvestorModule.Allocation[] memory allocation = new SplitInvestorModule.Allocation[](3);
        allocation[0] = SplitInvestorModule.Allocation(5_000, 0);
        allocation[1] = SplitInvestorModule.Allocation(2_500, 0);
        allocation[2] = SplitInvestorModule.Allocation(2_500, 0);
        
        splitInvestorModule.setAllocation(allocationList, allocation);

        vm.startPrank(owner);
        fundingToken.approve(instance.account, 20 ether);
        splitInvestorModule.depositAndInvest(instance.account, 10 ether, abi.encode(instance.aux.executorManager));
        vm.stopPrank();


        // Should have the correct balance of btc and steth
        assertEq(fundingToken.balanceOf(instance.account), 0);
        assertEq(btc.balanceOf(instance.account), 5 ether);
        assertEq(steth.balanceOf(instance.account), 2.5 ether);
        assertEq(matic.balanceOf(instance.account), 2.5 ether);

        splitInvestorModule.setTokenPrice(address(btc), 2 ether);
        splitInvestorModule.setTokenPrice(address(steth), 2 ether);
        splitInvestorModule.setTokenPrice(address(matic), 0.5 ether);

        bytes memory rebalancingAmounts = splitInvestorModule.calculateRebalance(instance.account);
        assertEq(rebalancingAmounts, abi.encodePacked(bytes32(abi.encodePacked(bytes1(0), bytes1(0x32), bytes1(0x01), bytes1(0x32))), bytes32(abi.encodePacked(bytes1(0x02),bytes1(0x64)))));

        // call fullfill request
        vm.startPrank(address(chainlinkRouter));
        string[] memory args = new string[](2);
        args[0] = instance.account.toHexString();
        chainlinkRouter.setAccount(instance.account); // instead of figuring out how to use cbor to decode
        splitInvestorModule.sendRebalanceRequest("code", bytes(""), args, uint64(bytes8("sub_id")), bytes32(uint256(123)));
        chainlinkRouter.respondRequest();

        assertEq(splitInvestorModule.lastRequestId(), bytes32(uint256(1337)));
        assertEq(splitInvestorModule.lastResponse(), bytes(abi.encodePacked()));
        // should have the same initial balances
        // assertEq(btc.balanceOf(instance.account), 2.5 ether);
        // assertEq(steth.balanceOf(instance.account), 1.25 ether);
        // assertEq(matic.balanceOf(instance.account), 5 ether);
    }
}
