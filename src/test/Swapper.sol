// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "@src/executors/SplitInvestorModule.sol";
import "@src/test/MockToken.sol";
import "forge-std/console.sol";

// this is a MOCK
contract Swapper {
    

    // Transfers token1 in and mints exactly 1:1
    function swap(address _token1, uint256 token1Amount, address _token2) public returns (uint256){
        MockToken(_token1).transferFrom(msg.sender, address(this), token1Amount);
        MockToken(_token2).mint(msg.sender, token1Amount);

        return token1Amount;
    }
}