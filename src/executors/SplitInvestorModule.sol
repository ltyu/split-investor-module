// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import { FunctionsClient } from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import { FunctionsRequest } from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import { ExecutorBase } from "modulekit/modulekit/ExecutorBase.sol";
import { IExecutorManager, ExecutorAction, ModuleExecLib } from "modulekit/modulekit/IExecutor.sol";

contract SplitInvestorModule is ExecutorBase, FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;
    using ModuleExecLib for IExecutorManager;
    uint32 public constant MAX_CALLBACK_GAS = 70_000;

    // A list of token addresses that this wallet wants to invest in
    address[] allocationEnumerated;

    // Allocation percentages for each token address 
    // @dev represented with 2 decimal places (10000 = 100%)
    mapping(address token => uint16 percentage) allocationPercentages;

    // Chainlink subscription Id for consumer
    uint64 subscriptionId;

    // Chainlink Job Id
    bytes32 jobId;

    // Chainlink last response Id
    bytes32 public lastRequestId;

    // Chainlink last responses from fulfillRequest()
    bytes32 public lastResponse;
    bytes32 public lastError;
    uint32 public lastResponseLength;
    uint32 public lastErrorLength;

    error UnexpectedRequestID(bytes32 requestId);

    constructor(address router) FunctionsClient(router) {}

    /**
     * @notice Sets the allocation %
     * @param _tokensToAllocate a list of tokens to
     */
    function setAllocation(address[] calldata _tokensToAllocate) external {

    }


    /**
     * @notice Deposits USDC and invest based on allocation %
     * @param account address of the account
     * @param data bytes data to be used for execution
     */
    function depositAndInvest(address account, bytes memory data) external {
        // Get the manager from data
        (IExecutorManager manager) = abi.decode(data, (IExecutorManager));

        // Create the actions to be executed
        ExecutorAction[] memory actions = new ExecutorAction[](2);


        // Deposit USDC

        // Buy x% of ETH 

        // Buy y% of BTC
        actions[0] = ExecutorAction({ to: payable(msg.sender), value: 1 wei, data: "" });

        // Execute the actions
        manager.exec(account, actions);
    }

    /// @notice Send a rebalance request through Chainlink Functions
    /// @param source JavaScript source code
    /// @param encryptedSecretsReferences Encrypted secrets payload
    /// @param args List of arguments accessible from within the source code
    /// @param _subscriptionId Billing ID
    function calculateRebalances(
        string calldata source,
        bytes calldata encryptedSecretsReferences,
        string[] calldata args,
        uint64 _subscriptionId,
        bytes32 _jobId
    ) external {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        if (encryptedSecretsReferences.length > 0) req.addSecretsReference(encryptedSecretsReferences);
        if (args.length > 0) req.setArgs(args);
        lastRequestId = _sendRequest(req.encodeCBOR(), _subscriptionId, MAX_CALLBACK_GAS, _jobId);
    }

    /// @notice Store latest Chainlink Function result/error
    /// @param requestId The request ID, returned by sendRequest()
    /// @param response Aggregated response from the user code
    /// @param err Aggregated error from the user code or from the execution pipeline
    /// @dev Either response or error parameter will be set, but never both
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId);
        }
        // Save only the first 32 bytes of response/error to always fit within MAX_CALLBACK_GAS
        lastResponse = bytesToBytes32(response);
        lastResponseLength = uint32(response.length);
        lastError = bytesToBytes32(err);
        lastErrorLength = uint32(err.length);

        _rebalance();
    }

    /**
     * @notice Rebalances the tokens based on allocationPercentages. Intends to be called by Chainlink 
     */
    function _rebalance() internal {

    }

    function bytesToBytes32(bytes memory b) private pure returns (bytes32 out) {
        uint256 maxLen = 32;
        if (b.length < 32) {
        maxLen = b.length;
        }
        for (uint256 i = 0; i < maxLen; ++i) {
        out |= bytes32(b[i]) >> (i * 8);
        }
        return out;
    }

    /**
     * @notice A funtion that returns name of the executor
     * @return name string name of the executor
     */
    function name() external view override returns (string memory name) {
        name = "ExecutorTemplate";
    }

    /**
     * @notice A funtion that returns version of the executor
     * @return version string version of the executor
     */
    function version() external view override returns (string memory version) {
        version = "0.0.1";
    }

    /**
     * @notice A funtion that returns version of the executor.
     * @return providerType uint256 Type of metadata provider
     * @return location bytes
     */
    function metadataProvider()
        external
        view
        override
        returns (uint256 providerType, bytes memory location)
    {
        providerType = 0;
        location = "";
    }

    /**
     * @notice A function that indicates if the executor requires root access to a Safe.
     * @return requiresRootAccess True if root access is required, false otherwise.
     */
    function requiresRootAccess() external view override returns (bool requiresRootAccess) {
        requiresRootAccess = false;
    }
}