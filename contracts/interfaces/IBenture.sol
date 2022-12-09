// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

/// @title Dividend-Paying Token Interface

/// @dev An interface for a dividend-paying token contract.
interface IBenture {
    /// @notice Distributes one token as dividends for holders of another token _equally _
    /// @param origToken The address of the token that is held by receivers
    ///        Can not be a zero address!
    ///        MUST be an address of a contract - not an address of EOA!
    /// @param distToken The address of the token that is to be distributed as dividends
    ///        Zero address for native token (ether, wei)
    /// @param amount The amount of distTokens to be distributed in total
    ///        NOTE: If dividends are to payed in ether then `amount` is the amount of wei (NOT ether!)
    function distributeDividendsEqual(
        address origToken,
        address distToken,
        uint256 amount
    ) external payable;

    /// @notice Distributes one token as dividends for holders of another token _according to each user's balance_
    /// @param origToken The address of the token that is held by receivers
    ///        Can not be a zero address!
    /// @param distToken The address of the token that is to be distributed as dividends
    ///        Zero address for native token (ether, wei)
    /// @param weight The amount of origTokens required to get a single distToken
    ///        NOTE: If dividends are payed in ether then `weight` is the amount of origTokens required to get a single ether (NOT a single wei!)
    function distributeDividendsWeighted(
        address origToken,
        address distToken,
        uint256 weight
    ) external payable;

    /// @dev Indicates that dividends were distributed
    /// @param distToken The address of dividend token that gets distributed
    /// @param amount The amount of distTokens to be distributed in total
    event DividendsDistributed(
        address indexed distToken,
        uint256 indexed amount
    );
}
