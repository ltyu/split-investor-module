// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FunctionsClient } from "chainlink/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import { FunctionsRequest } from "chainlink/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import { ExecutorBase } from "modulekit/modulekit/ExecutorBase.sol";
import { IExecutorManager, ExecutorAction, ModuleExecLib } from "modulekit/modulekit/IExecutor.sol";
import { Swapper } from "@src/test/Swapper.sol";
import "forge-std/console.sol";
contract SplitInvestorModule is ExecutorBase, FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;
    using ModuleExecLib for IExecutorManager;

    uint32 public constant MAX_CALLBACK_GAS = 500_000;
    uint16 public constant MAX_ALLOCATION_PERCENTAGE = 10_000;

    // Deposit Token that will be used to fund account
    IERC20 fundingToken;

    // A list of token addresses that this wallet wants to invest in
    // @dev For now we only handle up to 4 tokens for POC purposes
    address[] public allocationList;

    // Allocation percentages for each token address 
    // @dev represented with 2 decimal places (10000 = 100%)
    mapping(address token => Allocation allocation) public allocations;

    // Swapper (mocked for now, but can be Uniswap)
    Swapper swapper;

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
    error AllocationPercentageTooHigh();
    error LengthMismatch();
    error OnlySwapper();
    struct Allocation {
        uint16 percentage;
        uint256 notionalValue; // total USD value
    }

    constructor(address router, address _fundingToken, address _swapper) FunctionsClient(router) {
        fundingToken = IERC20(_fundingToken);
        swapper = Swapper(_swapper);
    }

    function allocationPercentage(address token) public view returns (uint16) {
        return allocations[token].percentage;
    }

    function allocationNotionalValue(address token) public view returns (uint256) {
        return allocations[token].notionalValue;
    }

    function allocationEnumeratedLength() public view returns (uint256) {
        return allocationList.length;
    }

    /**
     * @notice Sets the allocation %
     * @param _allocationList list of addresses to allocate
     * @param _allocations a list of allocations to set a percentage for
     */
    function setAllocation(address[] calldata  _allocationList, Allocation[] calldata _allocations) external {
        if (_allocationList.length != _allocations.length)
            revert LengthMismatch();

        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < _allocationList.length; i++) {
            allocations[_allocationList[i]].percentage = _allocations[i].percentage;
            totalPercentage += _allocations[i].percentage;
        }

        allocationList = _allocationList;

        if (totalPercentage > MAX_ALLOCATION_PERCENTAGE)
            revert AllocationPercentageTooHigh();
    }


    /**
     * @notice Deposits USDC and invest based on allocation %
     * @param account address of the account
     * @param data bytes data to be used for execution
     */
    function depositAndInvest(address account, uint256 amount, bytes memory data) external {
        // Get the manager from data
        (IExecutorManager manager) = abi.decode(data, (IExecutorManager));

        uint256 totalAllocations = allocationList.length;
        
        // @TODO do we need account here, or can we reference the SCA?
        ExecutorAction[] memory actions = _createDepositAndSwapActions(account, amount, totalAllocations);
        
        // Execute the actions
        manager.exec(account, actions);
    }

    // @dev this function also sets the notionalValue for each token allocated
    function _createDepositAndSwapActions(address account, uint amount, uint256 totalAllocations) internal returns (ExecutorAction[] memory actions){
        // Create the actions to be executed
        // 1 action for fundingToken.transferFrom, and 2 for each loop creating 2 actions
        actions = new ExecutorAction[]((totalAllocations * 2) + 1); 

        // Deposit USDC
        actions[0] = ExecutorAction({ 
            to: payable(address(fundingToken)), 
            value: 0,
            data: abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, account, amount)
        });

        for (uint256 i; i < totalAllocations; i++) {
            address tokenToAllocate = allocationList[i];
            uint256 allocatedAmount = _calculateAllocationAmount(tokenToAllocate, amount);

            // Sets the notional value.
            allocations[tokenToAllocate].notionalValue = allocatedAmount;

            // Approve swapper
            actions[i * 2 + 1] = ExecutorAction({ 
                to: payable(address(fundingToken)), 
                value: 0,
                data: abi.encodeWithSignature("approve(address,uint256)", address(swapper), amount)
            });

            // Swap
            actions[i * 2 + 2] = ExecutorAction({ 
                to: payable(address(swapper)), 
                value: 0,
                data: abi.encodeWithSignature("swap(address,uint256,address)", fundingToken, allocatedAmount, tokenToAllocate)
            });
        }
    }

    function setAllocationNotional(address tokenToAllocate, uint256 allocationAmount) public {
        allocations[tokenToAllocate].notionalValue = allocationAmount;
    }

    function _calculateAllocationAmount(address token, uint256 fundingAmount) view internal returns(uint256) {
        return fundingAmount = fundingAmount * allocations[token].percentage / MAX_ALLOCATION_PERCENTAGE;
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
        // @dev Technically Chainlink Functions can return up to 256 BYTES. For now, we'll keep it at 32.
        lastResponse = bytesToBytes32(response);
        lastResponseLength = uint32(response.length);
        lastError = bytesToBytes32(err);
        lastErrorLength = uint32(err.length);

        _rebalance();
    }

    /**
     * @notice Calculates the rebalance amounts
     * returns a byte32, 1 byte for buy/sell and 7 bytes for amount. 7 bytes allows up to 2^56 
     * 
     * for example 0x0100000000038ea8000000000040992f000f0a5d01ed64ff0100000000000000
     *      1 38EA8 means sell 233128 of token at index 0
     *      0 4233519 means buy 4233519 of token at index 1
     *      0 F0A5D01ED64FF means sell 4233519231231231 of token at index 2
     *      1 0000000 means buy 0000000 of token at index 3
     * 
     * @dev the intention is to allow this to be called by Chainlink Functions
     */
    function calculateRebalance() public returns (bytes32){
        // Get the stored lastCalculatedNotional for each token
        uint56 amount1 = 233128;
        bytes8 results1 = bytes8(abi.encodePacked(bytes1(0x01), bytes7(abi.encodePacked(amount1))));

        uint56 amount2 = 4233519;
        bytes8 results2 = bytes8(abi.encodePacked(bytes1(0x00), bytes7(abi.encodePacked(amount2))));

        uint56 amount3 = 0;
        bytes8 results3 = bytes8(abi.encodePacked(bytes1(0x01), bytes7(abi.encodePacked(amount3))));

        uint56 amount4 = 4233519231231231;
        bytes8 results4 = bytes8(abi.encodePacked(bytes1(0x00), bytes7(abi.encodePacked(amount4))));
        return bytes32(abi.encodePacked(results1, results2, results4, results3 ));
        // Calculate the new notional of each allocatedTokensList

        // For each token, store (newCalculatedNotional - lastCalculatedNotional), if result is positive
    }
    /**
     * @notice Rebalances the tokens based on allocations. Intends to be called by Chainlink 
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
