// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./interfaces/IBentureProducedToken.sol";
import "./interfaces/IBentureAdmin.sol";

contract BentureProducedToken is ERC20, IBentureProducedToken, Initializable {

    string internal _tokenName;
    string internal _tokenSymbol;
    uint8 internal _decimals;
    bool internal _mintable;
    /// @dev The address of the admin token has to be provided in order
    ///      to verify user's ownership of that token
    address internal _adminToken;
    /// @dev The maximum number of tokens to be minted
    uint256 internal _maxTotalSupply;
    /// @dev A list of addresses of tokens holders
    address[] internal _holders;
    /// @dev A mapping of holder's address and his position in `_holders` array
    mapping(address => uint256) internal _holdersIndexes;
    /// @dev A mapping of holders addresses that have received tokens
    mapping(address => bool) internal _usedHolders;

    /// @dev Checks if mintability is activated
    modifier WhenMintable() { 
        require (_mintable, "BentureProducedToken: the token is not mintable!"); 
        _; 
    }

    /// @dev Checks if caller is an admin token holder
    modifier hasAdminToken() {
        IBentureAdmin(_adminToken).verifyAdminToken(msg.sender, address(this));
        _;
    }

    /// @dev Creates a new controlled ERC20 token. 
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
        require(bytes(name_).length > 0, "BentureProducedToken: initial token name can not be empty!");
        require(bytes(symbol_).length > 0, "BentureProducedToken: initial token symbol can not be empty!");
        require(decimals_ > 0, "BentureProducedToken: initial decimals can not be zero!");
        require(adminToken_ != address(0), "BentureProducedToken: admin token address can not be a zero address!");
        if (mintable_) {
            require(maxTotalSupply_ != 0, "BentureProducedToken: max total supply can not be zero!");
        } else {
            require(maxTotalSupply_ == 0, "BentureProducedToken: max total supply must be zero for unmintable tokens!");
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
    function name() public view override(ERC20, IBentureProducedToken) returns(string memory) {
        return _tokenName;
    }

    /// @notice Returns the symbol of the token
    /// @return The symbol of the token
    function symbol() public view override(ERC20, IBentureProducedToken) returns(string memory) {
        return _tokenSymbol;
    }

    /// @notice Returns number of decimals of the token
    /// @return The number of decimals of the token
    function decimals() public view override(ERC20, IBentureProducedToken) returns(uint8) {
        return _decimals;
    }

    /// @notice Indicates whether the token is mintable or not
    /// @return True if the token is mintable. False - if it is not
    function mintable() external view override returns(bool) {
        return _mintable;
    }


    /// @notice Returns the array of addresses of all token holders
    /// @return The array of addresses of all token holders
    function holders() external view returns (address[] memory) {
        return _holders;
    }

    /// @notice Creates tokens and assigns them to account, increasing the total supply.
    /// @param to The receiver of tokens
    /// @param amount The amount of tokens to mint
    /// @dev Can only be called by the owner of the admin NFT
    /// @dev Can only be called when token is mintable
    function mint(address to, uint256 amount) external override hasAdminToken WhenMintable {
        require(to != address(0), "BentureProducedToken: can not mint to zero address!");
        require(totalSupply() + amount <= _maxTotalSupply, "BentureProducedToken: supply exceeds maximum supply!");
        emit ControlledTokenCreated(to, amount);
        // If there are any holders then add address to holders only if it's not there already
        if (_holders.length > 0) {
            if (_holdersIndexes[to] == 0 && _holders[0] != to) {
                // Push another address to the end of the array
                _holders.push(to);
                // Remember this address position
                _holdersIndexes[to] = _holders.length - 1;  
                // Mark holder's address as used
                _usedHolders[to] = true;
            }
        // If there are no holders then add the first one
        } else {
            _holders.push(to);
            _holdersIndexes[to] = _holders.length - 1;  
            _usedHolders[to] = true;
        }
       
        _mint(to, amount);
    }

    /// @notice Burns user's tokens
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external override {
        address caller = msg.sender;
        require(amount > 0, "BentureProducedToken: the amount of tokens to burn must be greater than zero!");
        require(balanceOf(caller) != 0, "BentureProducedToken: caller does not have any tokens to burn!");
        emit ControlledTokenBurnt(caller, amount);
        _burn(caller, amount);
        // If the whole supply of tokens has been burnt - remove the address from holders
        if(totalSupply() == 0) {
            // NOTE: `delete` does not change the length of any array. It replaces a "deleted" item
            //        with a default value
            // Get the addresses position and delete it from the array
            delete _holders[_holdersIndexes[caller]];  
            // Delete its index as well
            delete _holdersIndexes[caller];
            // Mark this holder as unused
            delete _usedHolders[caller];
        }
    }


    /// @notice Moves tokens from one account to another account
    /// @param from The address to transfer from
    /// @param to The address to transfer to
    /// @param amount The amount of tokens to be transfered
    /// @dev It is called by high-level functions. That is why it is necessary to override it
    /// @dev Transfers are permitted for everyone - not just admin token holders
    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "BentureProducedToken: sender can not be a zero address!");
        require(to != address(0), "BentureProducedToken: receiver can not be a zero address!");
        require(_usedHolders[from], "BentureProducedToken: sender does not have any tokens to transfer!");
        emit ControlledTokenTransferred(from, to, amount);
        // If the receiver is not yet a holder, he becomes a holder
        if (!_usedHolders[to]) {
            // Push another address to the end of the array
            _holders.push(to);
            // Remember the position of this address
            _holdersIndexes[to] = _holders.length - 1;  
            // Mark holder's address as used
            _usedHolders[to] = true;
        }
        // If all tokens of the holder get transfered - he is no longer a holder
        uint256 fromBalance = balanceOf(from);
        if (amount >= fromBalance) {
            // NOTE: `delete` does not change the length of any array. It replaces a "deleted" item
            //        with a default value
            // Get the addresses position and delete it from the array
            delete _holders[_holdersIndexes[from]];  
            // Delete its index as well
            delete _holdersIndexes[from];
            // Mark this holder as unused
            delete _usedHolders[from];
        }
        super._transfer(from, to, amount);
    }
}