// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import "@src/executors/SplitInvestorModule.sol";
import "forge-std/console.sol";

contract MockRouter {
    SplitInvestorModule splitInvestorModule;

    // SCA address set by sendRequest
    address account;

    function setSplitModule(address _splitInvestorModule) external {
        splitInvestorModule = SplitInvestorModule(_splitInvestorModule);
    }

    function setAccount(address _account) public {
        account = _account;
    }

    function sendRequest(uint64 subscriptionId,
        bytes calldata data,
        uint16 dataVersion,
        uint32 callbackGasLimit,
        bytes32 donId
    ) external returns (bytes32) {
        bytes32 requestId = bytes32(uint256(1337));
        return requestId;
    }

    // Calls splitInvestorModule.handleOracleFulfillment and returns a response after sendRequest
    function respondRequest() external {
        bytes memory rebalancingAmounts = splitInvestorModule.calculateRebalanceAmounts(account);
        splitInvestorModule.handleOracleFulfillment(bytes32(uint256(1337)), rebalancingAmounts, bytes(""));
    }
}