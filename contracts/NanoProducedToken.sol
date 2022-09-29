// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./interfaces/INanoProducedToken.sol";
import "./interfaces/INanoAdmin.sol";


contract NanoProducedToken is ERC20, INanoProducedToken, Initializable {

    string internal _tokenName;
    string internal _tokenSymbol;
    uint8 internal _decimals;
    bool internal _mintable;
    /// @dev The address of the admin tokens has to be provided in order
    ///      to verify user's ownership of that token
    address internal _adminToken;
    /// @dev Should be equal to `_initialSupply` for unmintable tokens
    uint256 internal _maxTotalSupply;
    /// @dev A list of addresses of tokens holders
    address[] internal _holders;
    /// @dev A mapping of holder's address and his position in `_holders` list
    mapping(address => uint256) internal _holdersIndexes;
    /// @dev A mapping of holders addresses that have received tokens
    mapping(address => bool) internal _usedHolders;
    /// @dev The address of the factory minting controlled tokens
    address private _factoryAddress;


    /// @dev Checks if mintability is activated
    modifier WhenMintable() { 
        require (_mintable, "NanoProducedToken: the token is not mintable!"); 
        _; 
    }

    /// @dev Checks if caller is an admin token holder
    modifier hasAdminToken() {
        // Get the ID of the admin token the caller has. If any.
        uint256 tokenId = INanoAdmin(_adminToken).checkOwner(msg.sender);
        // Get the address of the controlled token
        address contolledAddress = INanoAdmin(_adminToken).getControlledAddressById(tokenId);
        // Compare the previous address of the controlled token with the address of this contract
        require(contolledAddress == address(this), "NanoProducedToken: caller does not have an admin token!");
        _;
    }

    /// @dev Creates a new controlled ERC20 token. 
    /// @dev Only the owner (factory) can initialize the token
    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    /// @param decimals_ Number of decimals of the token
    /// @param mintable_ Token may be either mintable or not. Can be changed later.
    /// @param maxTotalSupply_ Maximum amount of tokens to be minted
    /// @param adminToken_ Address of the admin token for controlled token
    /// @dev Only the factory can initialize controlled tokens
    constructor (
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        bool mintable_,
        uint256 maxTotalSupply_,
        address adminToken_
    ) ERC20(name_, symbol_) {
        require(bytes(name_).length > 0, "NanoProducedToken: initial token name can not be empty!");
        require(bytes(symbol_).length > 0, "NanoProducedToken: initial token symbol can not be empty!");
        require(decimals_ > 0, "NanoProducedToken: initial decimals can not be zero!");
        require(adminToken_ != address(0), "NanoProducedToken: admin token address can not be a zero address!");
        if (mintable_) {
            require(maxTotalSupply_ != 0, "NanoProducedToken: max total supply can not be zero!");
        } else {
            require(maxTotalSupply_ == 0, "NanoProducedToken: max total supply must be zero for unmintable tokens!");
        }
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _decimals = decimals_;
        _mintable = mintable_;
        _maxTotalSupply = maxTotalSupply_;
        _adminToken = adminToken_;

    }


    /// @notice Returns the name of the token
    /// @return The name of the token
    function name() public view override(ERC20, INanoProducedToken) returns(string memory) {
        return _tokenName;
    }

    /// @notice Returns the symbol of the token
    /// @return The symbol of the token
    function symbol() public view override(ERC20, INanoProducedToken) returns(string memory) {
        return _tokenSymbol;
    }

    /// @notice Returns number of decimals of the token
    /// @return The number of decimals of the token
    function decimals() public view override(ERC20, INanoProducedToken) returns(uint8) {
        return _decimals;
    }

    /// @notice Indicates whether the token is mintable or not
    /// @return True if the token is mintable. False - if it is not
    function mintable() public view override returns(bool) {
        return _mintable;
    }

    /// @notice Returns the array of addresses of all token holders
    /// @return The array of addresses of all token holders
    function holders() public view returns (address[] memory) {
        return _holders;
    }

    /// @notice Creates tokens and assigns them to account, increasing the total supply.
    /// @param to The receiver of tokens
    /// @param amount The amount of tokens to mint
    /// @dev Can only be called by the owner of the admin NFT
    function mint(address to, uint256 amount) public override hasAdminToken WhenMintable {
        require(totalSupply() + amount <= _maxTotalSupply, "NanoProducedToken: supply exceeds maximum supply!");
        // Add address to holders only it it's not there already
        if (_holders[_holdersIndexes[to]] == address(0)) {
            // Push another address to the end of the array
            _holders.push(to);
            // Remember this address position
            _holdersIndexes[to] = _holders.length - 1;  
            // Mark holder's address as used
            _usedHolders[to] = true;
        }

        _mint(to, amount);
        emit ControlledTokenCreated(to, amount);
    }

    /// @notice Burns tokens, reducing the total supply.
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    /// @dev Can only be called by the owner of the admin NFT
    function burn(address from, uint256 amount) public override hasAdminToken {
        require(amount > 0, "NanoProducedToken: the amount of tokens to burn must be greater than zero!");
        require(_holders[_holdersIndexes[from]] != address(0), "NanoProducedToken: tokens have already been burnt!");
        _burn(from, amount);
        // If the whole supply of tokens has been burnt - remove the address from holders
        if(totalSupply() == 0) {
            // Get the addresses position and delete it from the array
            delete _holders[_holdersIndexes[from]];  
            // Delete its index as well
            delete _holdersIndexes[from];
            // Mark this holder as unused
            delete _usedHolders[from];
        }
        emit ControlledTokenBurnt(from, amount);
    }


    /// @notice Moves tokens from one account to another account
    /// @param from The address to transfer tokens from
    /// @param to The address to transfer tokens to
    /// @param amount The amount of tokens to be moved
    /// @dev It is called by high-level functions. That is why it is necessary to override it
    /// @dev Transfers are permitted for everyone - not just admin token holders
    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "NanoProducedToken: sender can not be a zero address!");
        require(to != address(0), "NanoProducedToken: receiver can not be a zero address!");
        // If the receiver is not yet a holder, he becomes a holder
        if (_usedHolders[to] != true) {
            // Push another address to the end of the array
            _holders.push(to);
            // Remember this address position
            _holdersIndexes[to] = _holders.length - 1;  
            // Mark holder's address as used
            _usedHolders[to] = true;
        }
        // If all tokens of the holder get transfered - he is no longer a holder
        // Negative numbers are allowed here but they will cause a revert inside dafault `_transfer` below
        uint256 fromBalance = balanceOf(from);
        if (fromBalance - amount <= 0) {
            // Get the addresses position and delete it from the array
            delete _holders[_holdersIndexes[from]];  
            // Delete its index as well
            delete _holdersIndexes[from];
            // Mark this holder as unused
            delete _usedHolders[from];
        }

        // Do a low-level transfer
        _transfer(from, to, amount);

        emit ControlledTokenTransferred(from, to, amount);

    }

}
