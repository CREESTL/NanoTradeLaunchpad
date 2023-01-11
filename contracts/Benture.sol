// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./BentureProducedToken.sol";
import "./interfaces/IBenture.sol";
import "./interfaces/IBentureProducedToken.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Dividends distributing contract
contract Benture is IBenture, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;
    using SafeERC20 for IBentureProducedToken;

    /// @dev Pool to lock tokens
    struct Pool {
        address token; // The address of the token inside the pool
        uint256 totalLockers; // The number of users who locked their tokens
        uint256 totalLocked; // The amount of locked tokens
        mapping(address => bool) hasLocked; // Indicates that locker has locked his tokens
        mapping(address => bool) hasUnlocked; // Indicates that locker has unlocked his tokens
        address[] lockersArray; // These two arrays are used to be copied from pool into distribution
        uint256[] lockersLocks; // because it's impossible to copy a mapping. They simulate a mapping
    }

    /// @dev Stores information about a specific dividends distribution
    struct Distribution {
        uint256 id; // ID of distributiion
        address origToken; // The token owned by holders
        address distToken; // The token distributed to holders
        uint256 amount; // The amount of `distTokens` or native tokens paid to holders
        bool isEqual; // True if distribution is equal, false if it's weighted
        mapping(address => bool) hasClaimed; // Mapping showing that holder has withdrawn his dividends
        uint256 formulaLockers; // Copies the value of Pool.totalLockers when creating a distribution
        uint256 formulaLocked; // Copies the value of Pool.totalLocked when creating a distribution
        address[] formulaLockersArray; // These two arrays copy Pool.lockersArray and Pool.lockersLocks arrays
        uint256[] formulaLockersLocks;
        DistStatus status; // Current status of distribution
    }


    /// @dev Mapping of lockers indexes in lockersArray and lockersLocks arrays in Pool structure
    /// @dev Used to get values from Pool.lockersArray, Pool.lockersLocks
    ///      and Distribution.formulaLockersArray and Distribution.formulaLockersLocks
    mapping(address => mapping(address => uint256)) lockersIndexes;

    /// @notice Address of the factory used for projects creation
    address public factory;


    /// @dev All pools
    mapping(address => Pool) pools;

    /// @dev Incrementing IDs of distributions
    Counters.Counter internal distributionIds;
    /// @dev Mapping from distribution ID to the address of the admin
    ///      who started the distribution
    mapping(uint256 => address) internal distributionsToAdmins;
    /// @dev Mapping from admin address to the list of IDs of active distributions he started
    mapping(address => uint256[]) internal adminsToDistributions;
    /// @dev All distributions
    mapping(uint256 => Distribution) distributions;

    /// @dev Checks that caller is either an admin of a project or a factory
    modifier onlyAdminOrFactory(address token) {
        // If caller is neither a factory nor an admin - revert
        if (!(token == factory) && !(IBentureAdmin(token).verifyAdminToken(msg.sender, token) == true)) {
            revert("Benture: caller is neither admin nor factory!");
        }
        _;
    }

    /// @dev Checks that caller is an admin of a project
    modifier onlyAdmin(address token) {
        if (IBentureAdmin(token).verifyAdminToken(msg.sender, token) == false) {
            revert("Benture: caller is not an admin!");
        }
        _;
    }


    /// @dev The contract must be able to receive ether to pay dividends with it
    receive() external payable {}

    constructor(address factory_) {
        factory = factory_;
    }


    // ===== POOLS =====


    /// @notice Creates a new pool
    /// @param token The token that will be locked in the pool
    function createPool(address token) external onlyAdminOrFactory(token) {
        require(token != address(0), "Benture: pools can not hold zero address tokens!");

        emit PoolCreated(token);

        Pool storage newPool = pools[token];
        // Check that this pool has not yet been initialized with the token
        // There can't multiple pools of the same token
        require(newPool.token != token, "Benture: pool already exists!");
        newPool.token = token;
        // Other fields are initialized with default values
    }

    /// @notice Deletes a pool
    ///         After that all operations with the pool will fail
    /// @param token The token of the pool
    function deletePool(address token) external onlyAdmin(token) {
        require(token != address(0), "Benture: pools can not hold zero address tokens!");

        emit PoolDeleted(token);

        delete pools[token];
    }

    /// @notice Locks user's tokens in order for him to receive dividends later
    /// @param origToken The address of the token to lock
    /// @param amount The amount of tokens to lock
    function lockTokens(address origToken, uint256 amount) external payable {
        require(amount > 0, "Benture: can not lock zero tokens!");
        // Check that a pool to lock tokens exists
        require(pools[origToken].token != address(0), "Benture: pool does not exist!");

        Pool storage pool = pools[origToken];
        // Check that pool holds the same token. Just in case
        require(pool.token == origToken, "Benture: wrong token inside the pool!");
        // Make sure that pool's arrays are of a correct length
        require(pool.lockersArray.length == pool.lockersLocks.length, "Benture: invalid arrays in the pool!");
        // User should have origTokens to be able to lock them
        require(
            IBentureProducedToken(origToken).isHolder(msg.sender),
            "Benture: user does not have project tokens!"
        );
        // If user has already locked tokens in this pool, add new lock amount
        if (pool.hasLocked[msg.sender]) {
            pool.lockersLocks[lockersIndexes[origToken][msg.sender]] += amount;
            // Do not modify `lockersArray` of `lockersIndexes` here
        } else {
            // If user has never locked tokens, add him to the lockers list
            pool.lockersArray.push(msg.sender);
            pool.lockersLocks.push(amount);
            // Place his index to the global map
            lockersIndexes[origToken][msg.sender] = pool.lockersArray.length - 1;
            // Increase the total number of lockers in the pool
            pool.totalLockers += 1;
        }
        // Increase the total amount of locked tokens
        pool.totalLocked += amount;

        emit TokensLocked(msg.sender, origToken, amount);

        // NOTE: User must approve transfer of at least `amount` of tokens
        //       before calling this function
        // Transfer tokens from user to the contract
        IBentureProducedToken(origToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
    }


    // ===== DISTRIBUTIONS =====


    /// @notice Allows admin to distribute dividends among lockers
    /// @param origToken The tokens to the holders of which the dividends will be paid
    /// @param distToken The token that will be paid
    ///        Use zero address for native tokens
    /// @param amount The amount of ERC20 tokens that will be paid
    /// @param isEqual Indicates whether distribution will be equal
    function distributeDividends (
        address origToken,
        address distToken,
        uint256 amount,
        bool isEqual
    ) external payable {
        require(
            origToken != address(0),
            "Benture: original token can not have a zero address!"
        );
        // Check that caller is an admin of `origToken`
        require(IBentureProducedToken(origToken).checkAdmin(msg.sender), "BentureAdmin: user does not have an admin token!");
        // Amount can not be zero
        require(amount > 0, "Benture: dividends amount can not be zero!");
        if (distToken != address(0)) {
            // NOTE: Caller should approve transfer of at least `amount` of tokens with `ERC20.approve()`
            // before calling this function
            // Transfer tokens from admin to the contract
            IERC20(distToken).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        } else {
            // Check that enough native tokens were provided
            require(
                msg.value >= amount,
                "Benture: not enough native tokens were provided!"
            );
        }

        emit DividendsStarted(origToken, distToken, amount, isEqual);

        distributionIds.increment();
        // NOTE The lowest distribution ID is 1
        uint256 distributionId = distributionIds.current();
        // Mark that this admin started a distribution with the new ID
        distributionsToAdmins[distributionId] = msg.sender;
        // Create a new distribution
        Distribution storage newDistribution = distributions[distributionId];
        newDistribution.id = distributionId;
        newDistribution.origToken = origToken;
        newDistribution.distToken = distToken;
        newDistribution.amount = amount;
        newDistribution.isEqual = isEqual;
        // `hasClaimed` is initialized with default value
        newDistribution.formulaLockers = pools[origToken].totalLockers;
        newDistribution.formulaLocked = pools[origToken].totalLocked;
        newDistribution.formulaLockersArray = pools[origToken].lockersArray;
        newDistribution.formulaLockersLocks = pools[origToken].lockersLocks;
        newDistribution.id = distributionId;
        newDistribution.status = DistStatus.inProgress;

    }

    // TODO add it to `claimDividends` later
    /// @notice Calculates locker's share in the distribution
    /// @param id The ID of the distribution to calculates shares in
    function calculateShare(uint256 id) internal {
            // TODO do stuff here
    }


    // TODO add claim dividends here


    // ===== GETTERS =====


    /// @notice Returns info about the pool of a given token
    /// @param token The address of the token of the pool
    /// @return The address of the tokens in the pool.
    /// @return The number of users who locked their tokens in the pool
    /// @return The amount of locked tokens
    function getPool(address token) public view returns(address, uint256, uint256) {
        require(token != address(0), "Benture: pools can not hold zero address tokens!");
        Pool storage pool = pools[token];
        return (
            pool.token,
            pool.totalLockers,
            pool.totalLocked
        );
    }

    /// @notice Checks if user has locked tokens in the pool
    /// @param token The address of the token of the pool
    /// @return True if user has locked tokens. Otherwise - false
    function hasLockedTokens(address token) public view returns(bool) {
        require(token != address(0), "Benture: pools can not hold zero address tokens!");
        return pools[token].hasLocked[msg.sender];
    }

    /// @notice Checks if user has unlocked tokens from the pool
    /// @param token The address of the token of the pool
    /// @return True if user has unlocked tokens. Otherwise - false
    function hasUnlockedTokens(address token) public view returns(bool) {
        require(token != address(0), "Benture: pools can not hold zero address tokens!");
        return (pools[token].hasUnlocked[msg.sender]);
    }

    /// @notice Returns the amount of tokens locked by the caller
    /// @param token The address of the token of the pool
    /// @return The amount of tokens locked by the caller inside the pool
    function getAmountLocked(address token) public view returns(uint256) {
        require(token != address(0), "Benture: pools can not hold zero address tokens!");
        return pools[token].lockersLocks[lockersIndexes[token][msg.sender]];
    }


    /// @notice Returns the list of IDs of all distributions the admin has ever started
    /// @param admin The address of the admin
    /// @return The list of IDs of all distributions the admin has ever started
    function getDistributions(
        address admin
    ) public view returns (uint256[] memory) {
        // Do not check wheter the given address is actually an admin
        require(
            admin != address(0),
            "Benture: admin can not have a zero address!"
        );
        return adminsToDistributions[admin];
    }

    /// @notice Returns the distribution with the given ID
    /// @param id The ID of the distribution to search for
    /// @return All information about the distribution
    function getDistribution(
        uint256 id
    )
        public
        view
        returns (uint256, address, address, uint256, bool, DistStatus)
    {
        require(id >= 1, "Benture: ID of distribution must be greater than 1!");
        require(
            distributionsToAdmins[id] != address(0),
            "Benture: distribution with the given ID has not been annouced yet!"
        );
        Distribution storage distribution = distributions[id];
        return (
            distribution.id,
            distribution.origToken,
            distribution.distToken,
            distribution.amount,
            distribution.isEqual,
            distribution.status
        );
    }

    /// @notice Checks if the distribution with the given ID was started by the given admin
    /// @param id The ID of the distribution to check
    /// @param admin The address of the admin to check
    /// @return True if admin has started the distribution with the given ID. Otherwise - false.
    function checkStartedByAdmin(
        uint256 id,
        address admin
    ) public view returns (bool) {
        require(id >= 1, "Benture: ID of distribution must be greater than 1!");
        require(
            distributionsToAdmins[id] != address(0),
            "Benture: distribution with the given ID has not been annouced yet!"
        );
        require(
            admin != address(0),
            "Benture: admin can not have a zero address!"
        );
        if (distributionsToAdmins[id] == admin) {
            return true;
        }
        return false;
    }



    /// @dev Returns the current `distToken` address of this contract
    /// @param distToken The address of the token to get the balance in
    /// @return The `distToken` balance of this contract
    function getCurrentBalance(
        address distToken
    ) internal view returns (uint256) {
        uint256 balance;
        if (distToken != address(0)) {
            balance = IERC20(distToken).balanceOf(address(this));
        } else {
            balance = address(this).balance;
        }

        return balance;
    }

   }
