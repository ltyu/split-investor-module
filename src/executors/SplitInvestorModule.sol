// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import { BytesLib } from "@solidity-bytes-utils/BytesLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FunctionsClient } from "chainlink/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import { FunctionsRequest } from "chainlink/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import { ExecutorBase } from "modulekit/modulekit/ExecutorBase.sol";
import { IExecutorManager, ExecutorAction, ModuleExecLib } from "modulekit/modulekit/IExecutor.sol";
import { Swapper } from "@src/test/Swapper.sol";
import "forge-std/console.sol";

// @dev note that there is minimum access control. This allows faster prototyping for the hackathon
contract SplitInvestorModule is ExecutorBase, FunctionsClient {
    using BytesLib for bytes;
    using FunctionsRequest for FunctionsRequest.Request;
    using ModuleExecLib for IExecutorManager;

    uint32 public constant MAX_CALLBACK_GAS = 1_000_000;
    uint16 public constant MAX_ALLOCATION_PERCENTAGE = 10_000;
    uint256 public constant ORACLE_PRICE_PRECISION = 1 ether;

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
    bytes public lastResponse;
    bytes public lastError;
    uint32 public lastResponseLength;
    uint32 public lastErrorLength;

    // Hackathon use only
    // price of asset
    mapping(address asset => uint256 price) tokenPrices;

    IExecutorManager executionManager;

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

    function setAllocationNotional(address tokenToAllocate, uint256 allocationAmount) public {
        allocations[tokenToAllocate].notionalValue = allocationAmount;
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


    // @dev Hackathon use only. Refactor this!
    function setExecutionManager(address _executionManager) external {
        executionManager = IExecutorManager(_executionManager);
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

    function _calculateAllocationAmount(address token, uint256 fundingAmount) view internal returns(uint256) {
        return fundingAmount = fundingAmount * allocations[token].percentage / MAX_ALLOCATION_PERCENTAGE;
    }

    /// @notice Send a rebalance request through Chainlink Functions
    /// @param source JavaScript source code
    /// @param encryptedSecretsReferences Encrypted secrets payload
    /// @param args List of arguments accessible from within the source code
    /// @param _subscriptionId Billing ID
    function sendRebalanceRequest(
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
        // Save only the first 64 bytes of response/error to always fit within MAX_CALLBACK_GAS
        // @dev Technically Chainlink Functions can return up to 256 BYTES. For now, we'll keep it at 64.
        lastResponse = response;
        lastResponseLength = uint32(response.length);
        lastError = err;
        lastErrorLength = uint32(err.length);

        parseAmountsAndReblance();
    }

    /**
     * @notice Calculates the rebalance amounts
     * returns byte64, 32 bytes for buy amounts and 32 bytes for sell amounts
     * 
     * 
     * for example: 
     *      0x0032013200000000000000000000000000000000000000000000000000000000
     *        0264000000000000000000000000000000000000000000000000000000000000
     *      0032 means sell 50% of token at index 0
     *      0132 means sell 50% of token at index 1
     *      0264 means buy 100% of token at index 2
     * 1 byte for buy/sell and 1 byte for the percentage to sell
     * @dev the intention is to allow this to be called by Chainlink Functions
     */
    function calculateRebalanceAmounts(address account) public view returns (bytes memory rebalancingAmounts){ 
        bytes memory sellAmounts;
        bytes memory buyAmounts;

        // Calculate the new notional of each allocatedTokensList
        for (uint8 i; i < allocationList.length; i++) {
            address tokenToAllocate = allocationList[i];
            uint256 tokenPrice = getTokenPrice(tokenToAllocate);
            uint256 oldNotionalValue = allocations[tokenToAllocate].notionalValue;
            uint256 newNotionalValue = IERC20(tokenToAllocate).balanceOf(account) * tokenPrice / ORACLE_PRICE_PRECISION; // @audit probably unsafe to use balanceOf

            uint256 higherNotionalValue = Math.max(newNotionalValue, oldNotionalValue);
            uint256 lowerNotionalValue = Math.min(newNotionalValue, oldNotionalValue);
            
            uint256 percentageToChange = (higherNotionalValue - lowerNotionalValue) * 1 ether / newNotionalValue; 

            // @dev Round down to whole percentages
            uint8 percentageToChange_u8 = uint8(percentageToChange / 1e16);

            if (newNotionalValue > oldNotionalValue) {
                sellAmounts = abi.encodePacked(sellAmounts, bytes2(abi.encodePacked(uint16(i) << 8 | uint16(percentageToChange_u8))));
            } else {
                buyAmounts = abi.encodePacked(buyAmounts, bytes2(abi.encodePacked(uint16(i) << 8 | uint16(percentageToChange_u8))));
            }            
        }

        rebalancingAmounts = abi.encodePacked(bytes32(sellAmounts), bytes32(buyAmounts), account);
    }

    // @dev mock oracle
    function getTokenPrice(address token) public view returns (uint256) {
        return tokenPrices[token];
    }

    // @dev mock oracle
    function setTokenPrice(address token, uint256 price) public returns (uint256) {
        return tokenPrices[token] = price;
    }

    /**
     * @notice Rebalances the tokens based on allocations. Intends to be called by Chainlink 
     */
    function parseAmountsAndReblance() public {
        bytes memory _lastResponse = lastResponse;
        bytes memory sellAmounts = _lastResponse.slice(0, 32);
        bytes memory buyAmounts = _lastResponse.slice(32, 32);
        address account = address(bytes20(_lastResponse.slice(64, 20)));

        ExecutorAction[] memory actions = new ExecutorAction[](sellAmounts.length + buyAmounts.length);
        uint256 actionsIndex; // used to point to the current array to insert action

        // Sell for fundingToken
        for (uint i; i < sellAmounts.length; i+=2) {
            uint8 indexToSell = uint8(bytes1(sellAmounts.slice(i, 1)));
            uint8 percentageToSell = uint8(bytes1(sellAmounts.slice(i + 1, 1)));
            address tokenToSell = allocationList[indexToSell];
            
            if (percentageToSell > 0) {
                // sell
                uint256 amountToSell = IERC20(tokenToSell).balanceOf(account) * percentageToSell / 100;

                actions[actionsIndex] = ExecutorAction({ 
                    to: payable(address(tokenToSell)), 
                    value: 0,
                    data: abi.encodeWithSignature("approve(address,uint256)", address(swapper), amountToSell)
                });

                actions[actionsIndex + 1] = ExecutorAction({ 
                    to: payable(address(swapper)), 
                    value: 0,
                    data: abi.encodeWithSignature("swap(address,uint256,address)", tokenToSell, amountToSell, address(fundingToken))
                });
                actionsIndex += 2;
            }
        }

        // Buy using fundingToken
        for (uint i; i < buyAmounts.length; i+=2) {
            uint8 indexToBuy = uint8(bytes1(buyAmounts.slice(i, 1)));
            uint8 percentageToBuy = uint8(bytes1(buyAmounts.slice(i + 1, 1)));
            address tokenToBuy = allocationList[indexToBuy];
            
            if (percentageToBuy > 0) {
                // sell
                uint256 amountToBuy = IERC20(tokenToBuy).balanceOf(account) * percentageToBuy / 100;

                actions[actionsIndex] = ExecutorAction({ 
                    to: payable(address(tokenToBuy)), 
                    value: 0,
                    data: abi.encodeWithSignature("approve(address,uint256)", address(swapper), amountToBuy)
                });

                actions[actionsIndex + 1] = ExecutorAction({ 
                    to: payable(address(swapper)), 
                    value: 0,
                    data: abi.encodeWithSignature("swap(address,uint256,address)", address(fundingToken), amountToBuy, tokenToBuy )
                });
                actionsIndex += 2;
            }
        }


        // Execute the actions
        executionManager.exec(account, actions);
    }

    /**
     * @notice A funtion that returns name of the executor
     * @return name string name of the executor
     */
    function name() external view override returns (string memory name) {
        name = "SplitInvestorModule";
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
