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
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Dividends distributing contract
contract Benture is IBenture, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;
    using SafeERC20 for IBentureProducedToken;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Pool to lock tokens
    /// @dev `lockers` and `lockersArray` basically store the same list of addresses
    ///       but they are used for different purposes
    struct Pool {
        // The address of the token inside the pool
        address token;
        // The list of all lockers of the pool
        EnumerableSet.AddressSet lockers;
        // The amount of locked tokens
        uint256 totalLocked;
        // Mapping from user address to the amount of tokens currently locked by the user in the pool
        // Could be 0 if user has unlocked all his tokens
        mapping(address => uint256) lockedByUser;
        // Mapping from user address to distribution ID to locked tokens amount
        // Shows "to what amount was the user's locked changed before the distribution with the given ID"
        // If the value for ID10 is 0, that means that user's lock amount did not change before that distribution
        // If the value for ID10 is 500, that means that user's lock amount changed to 500 before that distibution.
        // Amounts locked for N-th distribution (used to calculate user's dividends) can only
        // be updated since the start of (N-1)-th distribution and till the start of the N-th
        // distribution. `distributionIds.current()` is the (N-1)-th distribution in our case.
        // So we have to increase it by one to get the ID of the upcoming distribution and
        // the amount locked for that distribution.
        // For example, if distribution ID476 has started and Bob adds 100 tokens to his 500 locked tokens
        // the pool, then his lock for the distribution ID477 should be 600.
        mapping(address => mapping(uint256 => uint256)) lockHistory;
        // Mapping from user address to a list of IDs of distributions *before which* user's lock amount was changed
        // For example an array of [1, 2] means that user's lock amount changed before 1st and 2nd distributions
        // `EnumerableSet` can't be used here because it does not *preserve* the order of IDs and we need that
        mapping(address => uint256[]) lockChangesIds;
        // Mapping indicating that before the distribution with the given ID, user's lock amount was changed
        // Basically, a `true` value for `[user][ID]` here means that this ID is *in* the `lockChangesIds[user]` array
        // So it's used to check if a given ID is in the array.
        mapping(address => mapping(uint256 => bool)) changedBeforeId;
    }

    /// @dev Stores information about a specific dividends distribution
    struct Distribution {
        // ID of distributiion
        uint256 id;
        // The token owned by holders
        address origToken;
        // The token distributed to holders
        address distToken;
        // The amount of `distTokens` or native tokens paid to holders
        uint256 amount;
        // True if distribution is equal, false if it's weighted
        bool isEqual;
        // Mapping showing that holder has withdrawn his dividends
        mapping(address => bool) hasClaimed;
        // Copies the length of `lockers` set from the pool
        uint256 formulaLockers;
        // Copies the value of Pool.totalLocked when creating a distribution
        uint256 formulaLocked;
    }

    /// @notice Address of the factory used for projects creation
    address public factory;

    /// @dev All pools
    mapping(address => Pool) private pools;

    /// @dev Incrementing IDs of distributions
    Counters.Counter internal distributionIds;
    /// @dev Mapping from distribution ID to the address of the admin
    ///      who started the distribution
    mapping(uint256 => address) internal distributionsToAdmins;
    /// @dev Mapping from admin address to the list of IDs of active distributions he started
    mapping(address => uint256[]) internal adminsToDistributions;
    /// @dev Mapping from distribution ID to the distribution
    mapping(uint256 => Distribution) private distributions;

    /// @dev Checks that caller is either an admin of a project or a factory
    modifier onlyAdminOrFactory(address token) {
        // Check if token has a zero address. If so, there is no way to
        // verify that caller is admin because it's impossible to
        // call verification method on zero address
        if (token == address(0)) {
            revert InvalidTokenAddress();
        }
        // If factory address is zero, that means that it hasn't been set
        if (factory == address(0)) {
            revert FactoryAddressNotSet();
        }
        // If caller is neither a factory nor an admin - revert
        if (
            !(msg.sender == factory) &&
            !(IBentureProducedToken(token).checkAdmin(msg.sender))
        ) {
            revert CallerNotAdminOrFactory();
        }
        _;
    }

    /// @dev The contract must be able to receive ether to pay dividends with it
    receive() external payable {}

    // ===== POOLS =====

    /// @notice Creates a new pool
    /// @param token The token that will be locked in the pool
    function createPool(address token) external onlyAdminOrFactory(token) {
        if (token == address(0)) {
            revert InvalidTokenAddress();
        }

        emit PoolCreated(token);

        Pool storage newPool = pools[token];
        // Check that this pool has not yet been initialized with the token
        // There can't multiple pools of the same token
        if (newPool.token == token) {
            revert PoolAlreadyExists();
        }
        newPool.token = token;
        // Other fields are initialized with default values
    }

    /// @notice Locks the provided amount of user's tokens in the pool
    /// @param origToken The address of the token to lock
    /// @param amount The amount of tokens to lock
    function lockTokens(address origToken, uint256 amount) public {
        if (amount == 0) {
            revert InvalidLockAmount();
        }
        // Token must have npn-zero address
        if (origToken == address(0)) {
            revert InvalidTokenAddress();
        }

        Pool storage pool = pools[origToken];
        // Check that a pool to lock tokens exists
        if (pool.token == address(0)) {
            revert PoolDoesNotExist();
        }
        // Check that pool holds the same token. Just in case
        if (pool.token != origToken) {
            revert WrongTokenInsideThePool();
        }
        // User should have origTokens to be able to lock them
        if (!IBentureProducedToken(origToken).isHolder(msg.sender)) {
            revert UserDoesNotHaveProjectTokens();
        }

        // If user has never locked tokens, add him to the lockers list
        if (!isLocker(pool.token, msg.sender)) {
            pool.lockers.add(msg.sender);
        }
        // Increase the total amount of locked tokens
        pool.totalLocked += amount;

        // Get user's current lock, increase it and copy to the history
        pool.lockedByUser[msg.sender] += amount;
        pool.lockHistory[msg.sender][distributionIds.current() + 1] = pool
            .lockedByUser[msg.sender];

        // Mark that the lock amount was changed before the next distribution
        pool.lockChangesIds[msg.sender].push(distributionIds.current() + 1);
        // Mark that current ID is in the array now
        pool.changedBeforeId[msg.sender][distributionIds.current() + 1] = true;

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

    /// @notice Locks all user's tokens in the pool
    /// @param origToken The address of the token to lock
    function lockAllTokens(address origToken) public {
        uint256 wholeBalance = IBentureProducedToken(origToken).balanceOf(
            msg.sender
        );
        lockTokens(origToken, wholeBalance);
    }

    /// @notice Shows which distributions the user took part in and hasn't claimed them
    /// @param user The address of the user to get distributions for
    /// @param token The address of the token that was distributed
    /// @return The list of IDs of distributions the user took part in
    function getParticipatedNotClaimed(
        address user,
        address token
    ) private view returns (uint256[] memory) {
        Pool storage pool = pools[token];
        // Get the list of distributions before which user's lock was changed
        uint256[] memory allIds = pool.lockChangesIds[user];
        // If the last distribution has not started yet - delete it
        // User couldn't take part in it
        if (allIds[allIds.length - 1] > distributionIds.current()) {
            uint256[] memory temp = new uint256[](allIds.length - 1);
            for (uint256 i = 0; i < allIds.length - 1; i++) {
                temp[i] = allIds[i];
            }
            allIds = temp;
        }
        // If there are no distributions left - return an empty array.
        // That means that user has not yet participated in any *started* distribution
        if (allIds.length == 0) {
            return allIds;
        }
        // If there is only one such distribution that means that
        // this was only one distribution in total and it has started
        // Check that he hasn't claimed it and if so - return
        if (allIds.length == 1) {
            if (!distributions[allIds[0]].hasClaimed[user]) {
                return allIds;
            } else {
                // Else return an empty array
                return new uint256[](0);
            }
        }

        // If there are more than 1 IDs in the array, that means that at least
        // one distribution has started

        // Get the history of user's lock amount changes
        mapping(uint256 => uint256) storage amounts = pool.lockHistory[user];

        // First iteration: just *count* the amount of distributions the user took part in
        // Left and right borders of search

        uint256 counter;
        // If the first ID wasn't claimed, add it to the list and increase the counter
        if (hasClaimed(allIds[0], user)) {
            counter = 0;
        } else {
            counter = 1;
        }
        for (uint256 i = 1; i < allIds.length; i++) {
            if (amounts[allIds[i]] != 0) {
                if (amounts[allIds[i - 1]] != 0) {
                    // If lock for the ID is not 0 and for previous ID it's not 0 as well
                    // than means that user took part in all IDs between these two
                    for (
                        uint256 j = allIds[i - 1] + 1;
                        j < allIds[i] + 1;
                        j++
                    ) {
                        if (!hasClaimed(j, user)) {
                            counter++;
                        }
                    }
                } else {
                    // If lock for the ID is not 0, but for the previous ID it is 0, that means
                    // that user increased his lock to non-zero only now, so he didn't take part in
                    // any previous IDs
                    if (!hasClaimed(allIds[i], user)) {
                        counter++;
                    }
                }
            } else {
                if (amounts[allIds[i - 1]] != 0) {
                    // If lock for the ID is 0 and is not 0 for the previous ID, that means that
                    // user has unlocked all his tokens and didn't take part in the ID
                    for (uint256 j = allIds[i - 1] + 1; j < allIds[i]; j++) {
                        if (!hasClaimed(j, user)) {
                            counter++;
                        }
                    }
                }
            }
        }

        if (amounts[allIds[allIds.length - 1]] != 0) {
            // If lock for the last ID isn't zero, that means that the user still has lock
            // in the pool till this moment and he took part in all IDs since then
            for (
                uint256 j = allIds[allIds.length - 1] + 1;
                j < distributionIds.current() + 1;
                j++
            ) {
                if (!hasClaimed(j, user)) {
                    counter++;
                }
            }
        }

        uint256[] memory tookPart = new uint256[](counter);

        // Second iteration: actually fill the array

        if (hasClaimed(allIds[0], user)) {
            counter = 0;
        } else {
            counter = 1;
            tookPart[0] = allIds[0];
        }
        for (uint256 i = 1; i < allIds.length; i++) {
            if (amounts[allIds[i]] != 0) {
                if (amounts[allIds[i - 1]] != 0) {
                    for (
                        uint256 j = allIds[i - 1] + 1;
                        j < allIds[i] + 1;
                        j++
                    ) {
                        if (!hasClaimed(j, user)) {
                            tookPart[counter] = j;
                            counter++;
                        }
                    }
                } else {
                    if (!hasClaimed(allIds[i], user)) {
                        tookPart[counter] = allIds[i];
                        counter++;
                    }
                }
            } else {
                if (amounts[allIds[i - 1]] != 0) {
                    for (uint256 j = allIds[i - 1] + 1; j < allIds[i]; j++) {
                        if (!hasClaimed(j, user)) {
                            tookPart[counter] = j;
                            counter++;
                        }
                    }
                }
            }
        }

        if (amounts[allIds[allIds.length - 1]] != 0) {
            for (
                uint256 j = allIds[allIds.length - 1] + 1;
                j < distributionIds.current() + 1;
                j++
            ) {
                if (!hasClaimed(j, user)) {
                    tookPart[counter] = j;
                    counter++;
                }
            }
        }
        return tookPart;
    }

    /// @notice Unlocks the provided amount of user's tokens from the pool
    /// @param origToken The address of the token to unlock
    /// @param amount The amount of tokens to unlock
    function unlockTokens(
        address origToken,
        uint256 amount
    ) external nonReentrant {
        _unlockTokens(origToken, amount);
    }

    /// @notice Unlocks the provided amount of user's tokens from the pool
    /// @param origToken The address of the token to unlock
    /// @param amount The amount of tokens to unlock
    function _unlockTokens(address origToken, uint256 amount) private {
        if (amount == 0) {
            revert InvalidUnlockAmount();
        }
        // Token must have npn-zero address
        if (origToken == address(0)) {
            revert InvalidTokenAddress();
        }

        Pool storage pool = pools[origToken];
        // Check that a pool to lock tokens exists
        if (pool.token == address(0)) {
            revert PoolDoesNotExist();
        }
        // Check that pool holds the same token. Just in case
        if (pool.token != origToken) {
            revert WrongTokenInsideThePool();
        }
        // Make sure that user has locked some tokens before
        if (!isLocker(pool.token, msg.sender)) {
            revert NoLockedTokens();
        }

        // Make sure that user is trying to withdraw no more tokens than he has locked for now
        if (pool.lockedByUser[msg.sender] < amount) {
            revert WithdrawTooBig();
        }

        // Any unlock triggers claim of all dividends inside the pool for that user

        // Get the list of distributions the user took part in and hasn't claimed them
        uint256[] memory notClaimedIds = getParticipatedNotClaimed(
            msg.sender,
            origToken
        );

        // Now claim all dividends of these distributions
        _claimMultipleDividends(notClaimedIds);

        // Decrease the total amount of locked tokens in the pool
        pool.totalLocked -= amount;

        // Get the current user's lock, decrease it and copy to the history
        pool.lockedByUser[msg.sender] -= amount;
        pool.lockHistory[msg.sender][distributionIds.current() + 1] = pool
            .lockedByUser[msg.sender];
        // Mark that the lock amount was changed before the next distribution
        pool.lockChangesIds[msg.sender].push(distributionIds.current() + 1);
        // Mark that current ID is in the array now
        pool.changedBeforeId[msg.sender][distributionIds.current() + 1] = true;

        // If all tokens were unlocked - delete user from lockers list
        if (pool.lockedByUser[msg.sender] == 0) {
            // Delete it from the set as well
            pool.lockers.remove(msg.sender);
        }

        emit TokensUnlocked(msg.sender, origToken, amount);

        // Transfer unlocked tokens from contract to the user
        IBentureProducedToken(origToken).safeTransfer(msg.sender, amount);
    }

    /// @notice Unlocks all locked tokens of the user in the pool
    /// @param origToken The address of the token to unlock
    function unlockAllTokens(address origToken) public {
        // Get the last lock of the user
        uint256 wholeBalance = pools[origToken].lockedByUser[msg.sender];
        // Unlock that amount (could be 0)
        _unlockTokens(origToken, wholeBalance);
    }

    // ===== DISTRIBUTIONS =====

    /// @notice Allows admin to distribute dividends among lockers
    /// @param origToken The tokens to the holders of which the dividends will be paid
    /// @param distToken The token that will be paid
    ///        Use zero address for native tokens
    /// @param amount The amount of ERC20 tokens that will be paid
    /// @param isEqual Indicates whether distribution will be equal
    function distributeDividends(
        address origToken,
        address distToken,
        uint256 amount,
        bool isEqual
    ) external payable nonReentrant {
        if (origToken == address(0)) {
            revert InvalidTokenAddress();
        }
        // Check that caller is an admin of `origToken`
        if (!IBentureProducedToken(origToken).checkAdmin(msg.sender)) {
            revert UserDoesNotHaveAnAdminToken();
        }
        // Amount can not be zero
        if (amount == 0) {
            revert InvalidDividendsAmount();
        }
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
            if (msg.value < amount) {
                revert NotEnoughNativeTokens();
            }
        }

        emit DividendsStarted(origToken, distToken, amount, isEqual);

        distributionIds.increment();
        // NOTE The lowest distribution ID is 1
        uint256 distributionId = distributionIds.current();
        // Mark that this admin started a distribution with the new ID
        distributionsToAdmins[distributionId] = msg.sender;
        adminsToDistributions[msg.sender].push(distributionId);
        // Create a new distribution
        Distribution storage newDistribution = distributions[distributionId];
        newDistribution.id = distributionId;
        newDistribution.origToken = origToken;
        newDistribution.distToken = distToken;
        newDistribution.amount = amount;
        newDistribution.isEqual = isEqual;
        // `hasClaimed` is initialized with default value
        newDistribution.formulaLockers = pools[origToken].lockers.length();
        newDistribution.formulaLocked = pools[origToken].totalLocked;
    }

    /// @dev Searches for the distribution that has an ID less than the `id`
    ///      but greater than all other IDs less than `id` and before which user's
    ///      lock amount was changed the last time. Returns the ID of that distribution
    ///      or (-1) if no such ID exists.
    ///      Performs a binary search.
    /// @param user The user to find a previous distribution for
    /// @param id The ID of the distribution to find a previous distribution for
    /// @return The ID of the found distribution. Or (-1) if no such distribution exists
    function findMaxPrev(
        address user,
        uint256 id
    ) internal view returns (int256) {
        address origToken = distributions[id].origToken;

        uint256[] storage ids = pools[origToken].lockChangesIds[user];

        // If the array is empty, there can't be a correct ID we're looking for in it
        if (ids.length == 0) {
            return -1;
        }

        // Start binary search
        uint256 low = 0;
        uint256 high = pools[origToken].lockChangesIds[user].length;

        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (pools[origToken].lockChangesIds[user][mid] > id) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        // After this loop `low` is the array index of the ID that is *greater* than the `id`.
        // (and we're looking for the one that is *less* than the `id`)

        // IDs are sorted in the ascending order.
        // If `low` is 0, that means that the first ID in the array is
        //    greater than the `id`. Thus there are no any IDs in the array that may be *less* than the `id`
        if (low == 0) {
            return -1;
        }

        // If the array actually contains the `id` at index N, that means that a greater value is located at the
        // N + 1 index in the array (which is `low`) and the *smaller* value is located at the N - 1
        // index in the array (which is `low - 2`)
        if (pools[origToken].changedBeforeId[user][id]) {
            // If `low` is 1, that means that the `id` is the first element of the array (index 0).
            // Thus there are no any IDs in the array that may be *less* then `id`
            if (low == 1) {
                return -1;
            }
            // If `low` is greater then 1, that means that there can be elements of the array at indexes
            // of `low - 2` that are less than the `id`
            return int256(ids[low - 2]);
            // If the array does not contain the `id` at index N (that is also possible if user's lock was not changed before that `id`),
            // that means that a greater value is located at the N + 1 index in the array (which is `low`) and the *smaller* value is located
            // at the *N* index in the array (which is `low - 1`)
            // The lowest possible value of `low` here is 1. 0 is excluded by one of the conditions above
        } else {
            return int256(ids[low - 1]);
        }
    }

    /// @notice Calculates locker's share in the distribution
    /// @param id The ID of the distribution to calculates shares in
    /// @param user The address of the user whos share has to be calculated
    function calculateShare(
        uint256 id,
        address user
    ) internal view returns (uint256) {
        Distribution storage distribution = distributions[id];
        Pool storage pool = pools[distribution.origToken];

        uint256 share;

        // Calculate shares if equal distribution
        if (distribution.isEqual) {
            // NOTE: result gets rounded towards zero
            // If the `amount` is less than `formulaLockers` then share is 0
            share = distribution.amount / distribution.formulaLockers;
            // Calculate shares in weighted distribution
        } else {
            // Get the amount locked by the user before the given distribution
            uint256 lock = pool.lockHistory[user][id];

            // If lock is zero, that means:
            // 1) The user has unlocked all his tokens before the given distribution
            // OR
            // 2) The user hasn't called either lock or unlock functions before the given distribution
            //    and because of that his locked amount was not updated in the mapping
            // So we have to determine which option is the right one
            if (lock == 0) {
                // Check if user has changed his lock amount before the distribution
                if (pool.changedBeforeId[user][id]) {
                    // If he did, and his current lock is 0, that means that he has unlocked all his tokens and 0 is a correct lock amount
                    lock = 0;
                } else {
                    // If he didn't, that means that *we have to use his lock from the closest distribution from the past*
                    // We have to find a distribution that has an ID that is less than `id` but greater than all other
                    // IDs less than `id`
                    int256 prevMaxId = findMaxPrev(user, id);
                    if (prevMaxId != -1) {
                        lock = pool.lockHistory[user][uint256(prevMaxId)];
                    } else {
                        // If no such an ID exists (i.e. there were no distributions before the current one that had non-zero locks before them)
                        // that means that a user has *locked and unlocked* his tokens before the very first distribution. In this case 0 is a correct lock amount
                        lock = 0;
                    }
                }
            }

            share = (distribution.amount * lock) / distribution.formulaLocked;
        }

        return share;
    }

    /// @notice Allows a user to claim dividends from a single distribution
    /// @param id The ID of the distribution to claim
    function claimDividends(uint256 id) external nonReentrant {
        _claimDividends(id);
    }

    function _claimDividends(uint256 id) private {
        // Can't claim a distribution that has not started yet
        if (id > distributionIds.current()) {
            revert DistributionHasNotStartedYet();
        }

        Distribution storage distribution = distributions[id];

        // User must be a locker of the `origToken` of the distribution he's trying to claim
        if (!isLocker(distribution.origToken, msg.sender)) {
            revert UserDoesNotHaveLockedTokens();
        }

        // User can't claim the same distribution more than once
        if (distribution.hasClaimed[msg.sender]) {
            revert AlreadyClaimed();
        }

        // Calculate the share of the user
        uint256 share = calculateShare(id, msg.sender);

        // If user's share is 0, that means he doesn't have any locked tokens
        if (share == 0) {
            revert UserDoesNotHaveLockedTokens();
        }

        emit DividendsClaimed(id, msg.sender);

        distribution.hasClaimed[msg.sender] = true;

        // Send the share to the user
        if (distribution.distToken == address(0)) {
            // Send native tokens
            (bool success, ) = msg.sender.call{value: share}("");
            if (!success) {
                revert NativeTokenTransferFailed();
            }
        } else {
            // Send ERC20 tokens
            IERC20(distribution.distToken).safeTransfer(msg.sender, share);
        }
    }

    /// @notice Allows user to claim dividends from multiple distributions
    ///         WARNING: Potentially can exceed block gas limit!
    /// @param ids The array of IDs of distributions to claim
    function claimMultipleDividends(
        uint256[] memory ids
    ) external nonReentrant {
        _claimMultipleDividends(ids);
    }

    function _claimMultipleDividends(uint256[] memory ids) private {
        // Only 2/3 of block gas limit could be spent. So 1/3 should be left.
        uint256 gasThreshold = (block.gaslimit * 1) / 3;

        uint256 count;

        for (uint i = 0; i < ids.length; i++) {
            _claimDividends(ids[i]);
            // Increase the number of users who received their shares
            count++;
            // Check that no more than 2/3 of block gas limit was spent
            if (gasleft() <= gasThreshold) {
                break;
            }
        }

        emit MultipleDividendsClaimed(msg.sender, count);
    }

    /// @notice Allows admin to distribute provided amounts of tokens to the provided list of users
    /// @param token The address of the token to be distributed
    /// @param users The list of addresses of users to receive tokens
    /// @param amounts The list of amounts each user has to receive
    /// @param totalAmount The total amount of `token`s to be distributed. Sum of `amounts` array.
    function distributeDividendsCustom(
        address token,
        address[] calldata users,
        uint256[] calldata amounts,
        uint256 totalAmount
    ) public payable nonReentrant {
        // Lists can't be empty
        if ((users.length == 0) || (amounts.length == 0)) {
            revert EmptyList();
        }
        // Lists length should be the same
        if (users.length != amounts.length) {
            revert ListsLengthDiffers();
        }
        // If dividends are to be paid in native tokens, check that enough native tokens were provided
        if ((token == address(0)) && (msg.value < totalAmount)) {
            revert NotEnoughNativeTokens();
        }
        // If dividends are to be paid in ERC20 tokens, transfer ERC20 tokens from caller
        // to this contract first
        // NOTE: Caller must approve transfer of at least `totalAmount` of tokens to this contract
        if (token != address(0)) {
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                totalAmount
            );
        }

        // Only 2/3 of block gas limit could be spent. So 1/3 should be left.
        uint256 gasThreshold = (block.gaslimit * 1) / 3;

        uint256 count;

        // Distribute dividends to each of the holders
        for (uint256 i = 0; i < users.length; i++) {
            // Users cannot have zero addresses
            if (users[i] == address(0)) {
                revert InvalidUserAddress();
            }
            // Amount for any user cannot be 0
            if (amounts[i] == 0) {
                revert InvalidDividendsAmount();
            }
            if (token == address(0)) {
                // Native tokens (wei)
                (bool success, ) = users[i].call{value: amounts[i]}("");
                if (!success) {
                    revert TransferFailed();
                }
            } else {
                // Other ERC20 tokens
                IERC20(token).safeTransfer(users[i], amounts[i]);
            }
            // Increase the number of users who received their shares
            count++;
            // Check that no more than 2/3 of block gas limit was spent
            if (gasleft() <= gasThreshold) {
                break;
            }
        }

        emit CustomDividendsDistributed(token, count);
    }

    /// @notice Sets the token factory contract address
    /// @param factoryAddress The address of the factory
    /// @dev NOTICE: This address can't be set the constructor because
    ///      `Benture` is deployed *before* factory contract.
    function setFactoryAddress(address factoryAddress) external onlyOwner {
        if (factoryAddress == address(0)) {
            revert InvalidFactoryAddress();
        }
        factory = factoryAddress;
    }

    // ===== GETTERS =====

    /// @notice Returns info about the pool of a given token
    /// @param token The address of the token of the pool
    /// @return The address of the tokens in the pool.
    /// @return The number of users who locked their tokens in the pool
    /// @return The amount of locked tokens
    function getPool(
        address token
    ) public view returns (address, uint256, uint256) {
        if (token == address(0)) {
            revert InvalidTokenAddress();
        }

        Pool storage pool = pools[token];
        return (pool.token, pool.lockers.length(), pool.totalLocked);
    }

    /// @notice Returns the array of lockers of the pool
    /// @param token The address of the token of the pool
    /// @return The array of lockers of the pool
    function getLockers(address token) public view returns (address[] memory) {
        if (token == address(0)) {
            revert InvalidTokenAddress();
        }

        return pools[token].lockers.values();
    }

    /// @notice Checks if user is a locker of the provided token pool
    /// @param token The address of the token of the pool
    /// @param user The address of the user to check
    /// @return True if user is a locker in the pool. Otherwise - false.
    function isLocker(address token, address user) public view returns (bool) {
        if (token == address(0)) {
            revert InvalidTokenAddress();
        }

        if (user == address(0)) {
            revert InvalidUserAddress();
        }
        // User is a locker if his lock is not a zero and he is in the lockers list
        return
            (pools[token].lockedByUser[user] != 0) &&
            (pools[token].lockers.contains(user));
    }

    /// @notice Returns the current lock amount of the user
    /// @param token The address of the token of the pool
    /// @param user The address of the user to check
    /// @return The current lock amount
    function getCurrentLock(
        address token,
        address user
    ) public view returns (uint256) {
        if (token == address(0)) {
            revert InvalidTokenAddress();
        }
        if (user == address(0)) {
            revert InvalidUserAddress();
        }
        return pools[token].lockedByUser[user];
    }

    /// @notice Returns the list of IDs of all distributions the admin has ever started
    /// @param admin The address of the admin
    /// @return The list of IDs of all distributions the admin has ever started
    function getDistributions(
        address admin
    ) public view returns (uint256[] memory) {
        // Do not check wheter the given address is actually an admin
        if (admin == address(0)) {
            revert InvalidAdminAddress();
        }
        return adminsToDistributions[admin];
    }

    /// @notice Returns the distribution with the given ID
    /// @param id The ID of the distribution to search for
    /// @return All information about the distribution
    function getDistribution(
        uint256 id
    ) public view returns (uint256, address, address, uint256, bool) {
        if (id < 1) {
            revert InvalidDistributionId();
        }
        if (distributionsToAdmins[id] == address(0)) {
            revert DistributionNotStarted();
        }
        Distribution storage distribution = distributions[id];
        return (
            distribution.id,
            distribution.origToken,
            distribution.distToken,
            distribution.amount,
            distribution.isEqual
        );
    }

    /// @notice Checks if user has claimed dividends of the provided distribution
    /// @param id The ID of the distribution to check
    /// @param user The address of the user to check
    /// @return True if user has claimed dividends. Otherwise - false
    function hasClaimed(uint256 id, address user) public view returns (bool) {
        if (id < 1) {
            revert InvalidDistributionId();
        }
        if (distributionsToAdmins[id] == address(0)) {
            revert DistributionNotStarted();
        }
        if (user == address(0)) {
            revert InvalidUserAddress();
        }
        return distributions[id].hasClaimed[user];
    }

    /// @notice Checks if the distribution with the given ID was started by the given admin
    /// @param id The ID of the distribution to check
    /// @param admin The address of the admin to check
    /// @return True if admin has started the distribution with the given ID. Otherwise - false.
    function checkStartedByAdmin(
        uint256 id,
        address admin
    ) public view returns (bool) {
        if (id < 1) {
            revert InvalidDistributionId();
        }
        if (distributionsToAdmins[id] == address(0)) {
            revert DistributionNotStarted();
        }
        if (admin == address(0)) {
            revert InvalidAdminAddress();
        }
        if (distributionsToAdmins[id] == admin) {
            return true;
        }
        return false;
    }

    /// @notice Returns the share of the user in a given distribution
    /// @param id The ID of the distribution to calculate share in
    function getMyShare(uint256 id) external view returns (uint256) {
        if (id > distributionIds.current() + 1) {
            revert InvalidDistribution();
        }
        // Only lockers might have shares
        if (!isLocker(distributions[id].origToken, msg.sender)) {
            revert CallerIsNotLocker();
        }
        return calculateShare(id, msg.sender);
    }
}
