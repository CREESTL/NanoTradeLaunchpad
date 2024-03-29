// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./BentureProducedToken.sol";
import "./interfaces/IBentureFactory.sol";
import "./interfaces/IBentureAdmin.sol";
import "./interfaces/IBenture.sol";

/// @title A factory of custom ERC20 tokens
contract BentureFactory is IBentureFactory {
    /// @dev The address of the `Benture` contract
    address private bentureAddress;

    /// @dev The address of the last token that was produced by the factory
    address private _lastProducedToken;

    constructor(address bentureAddress_) {
        if (bentureAddress_ == address(0)) {
            revert BentureAddressIsZero();
        }
        bentureAddress = bentureAddress_;
    }

    /// @notice Returns the address of the produced ERC20 token
    /// @return The address of the produced ERC20 token
    function lastProducedToken() external view returns (address) {
        return _lastProducedToken;
    }

    /// @notice Creates a new ERC20 token and mints an admin token proving ownership
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param decimals Number of decimals of the token
    /// @param mintable Token may be either mintable or not. Can be changed later.
    /// @param maxTotalSupply Maximum amount of tokens to be minted
    /// @param adminToken_ Address of the admin token for controlled token
    /// @dev Anyone can call this method. No restrictions.
    function createERC20Token(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bool mintable,
        uint256 maxTotalSupply,
        address adminToken_
    ) external {
        BentureProducedToken newToken = new BentureProducedToken(
            name,
            symbol,
            decimals,
            mintable,
            maxTotalSupply,
            adminToken_
        );

        emit CreateERC20Token(
            name,
            symbol,
            address(newToken),
            decimals,
            mintable
        );

        // The address of the produced token gets changed each time
        _lastProducedToken = address(newToken);

        // Mint admin token to the creator of this ERC20 token
        IBentureAdmin(adminToken_).mintWithERC20Address(
            msg.sender,
            address(newToken)
        );

        IBenture(bentureAddress).createPool(address(newToken));
    }
}
