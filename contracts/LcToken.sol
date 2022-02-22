// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Authorizable.sol";

import "./IProfiles.sol";

/**
 * @author DefiKingdoms
 * @title JewelToken
 */
contract LcToken is ERC20, Ownable, Authorizable {
    uint256 private _cap; // 激励总量
    uint256 private _releasedCap; // 已释放激励总量

    uint256 private _totalSupply; // token总量

    uint256 private _totalLock; // 锁定总量
    uint256 public lockFromBlock;
    uint256 public lockToBlock;
    uint256 public manualMintLimit;
    uint256 public manualMinted = 0;

    uint256 public manualReleaseLimit; // 手动释放的量
    uint256 public manualReleased = 0; // 已经手动释放

    address public miner; // 铸造token地址
    IProfiles public profilesContract;
    uint64 public profileAgeReq = 0;

    mapping(address => uint256) private _locks;
    mapping(address => uint256) private _lastUnlockBlock;

    // Max transfer amount rate in basis points. Default is 100% of total
    // supply, and it can't be less than 0.5% of the supply.
    // 最大转账金额利率（以基点为单位）。默认值为总供应量的 100%，不能低于总供应量的 0.5%。
    uint16 public maxTransferAmountRate = 10000;

    // Addresses that are excluded from anti-whale checking.
    // 从反鲸鱼检查中排除的地址。
    mapping(address => bool) private _excludedFromAntiWhale;

    // Events.
    event MaxTransferAmountRateUpdated(uint256 previousRate, uint256 newRate);
    event Lock(address indexed to, uint256 value);
    event Unlock(address indexed to, uint256 value);

    // Modifiers.

    /**
     * @dev Ensures that the anti-whale rules are enforced.
     *  确保执行反鲸鱼规则 防止大额转账破环市场
     */
    modifier antiWhale(address sender, address recipient, uint256 amount) {
        if (maxTransferAmount() > 0) {
            if (
                _excludedFromAntiWhale[sender] == false
                && _excludedFromAntiWhale[recipient] == false
            ) {
                require(amount <= maxTransferAmount(), "antiWhale: Transfer amount exceeds the maxTransferAmount");
            }
        }
        _;
    }

    /**
     * @dev Ensures that the recipient has a profile.
     */
    modifier onlyProfile(address sender, address recipient) {
        if (profileAgeReq > 0) {
            if (
                _excludedFromAntiWhale[recipient] == false
            ) {
                // Get the profile of the recipient, and check the age.
                uint64 _created = 0;
                (, , , _created, , , ) = profilesContract.getProfileByAddress(recipient);
                require(_created > 0 && ((block.timestamp - _created) > profileAgeReq), "profile not old enough");
            }
        }
        _;
    }
    /*
    constructor(
      string memory _name,
      string memory _symbol,
      uint256 cap_,
      uint256 _manualMintLimit,
      uint256 _lockFromBlock,
      uint256 _lockToBlock
    ) public ERC20(_name, _symbol) {
        _cap = cap_;
        manualMintLimit = _manualMintLimit;
        lockFromBlock = _lockFromBlock;
        lockToBlock = _lockToBlock;

        _excludedFromAntiWhale[msg.sender] = true;
        _excludedFromAntiWhale[address(0)] = true;
        _excludedFromAntiWhale[address(this)] = true;
    }
    */

    constructor(
      string memory _name,
      string memory _symbol,
      uint256 totalSupply_,
      uint256 cap_,
      uint256 _manualReleaseLimit,
      uint256 _lockFromBlock,
      uint256 _lockToBlock
    ) public ERC20(_name, _symbol) {
        _totalSupply = totalSupply_;
        _cap = cap_;
        manualReleaseLimit = _manualReleaseLimit;
        lockFromBlock = _lockFromBlock;
        lockToBlock = _lockToBlock;


        _excludedFromAntiWhale[msg.sender] = true;
        _excludedFromAntiWhale[address(0)] = true;
        _excludedFromAntiWhale[address(this)] = true;
    }

    function totalSupply() public view override returns(uint256){
        return _totalSupply;
    }

    /**
     * @dev Returns the cap on the token's reward supply.
     * 返回令牌总激励
     */
    function cap() public view returns (uint256) {
        return _cap;
    }
    // 返回已经释放的激励
    function releasedCap() public view returns (uint256) {
        return _releasedCap;
    }

    /**
     * @dev Updates the total cap.
     */
     // 更新激励总量上限
    function capUpdate(uint256 _newCap) public onlyAuthorized {
        _cap = _newCap;
    }

    /// @dev Sets the profiles contract.
    function setProfiles(address _profilesAddress) public onlyAuthorized returns (bool success) {
        IProfiles candidateContract = IProfiles(_profilesAddress);

        // Verify that it is an actual contract.
        require(candidateContract.heroesNftContract() != address(0), "invalid");

        // Set it.
        profilesContract = candidateContract;
        return true;
    }

    /// @dev Sets the profiles age requirement.
    function setProfileAgeReq(uint64 _age) public onlyAuthorized returns (bool success) {
        // Set it.
        profileAgeReq = _age;
        return true;
    }

    // Update the lockFromBlock
    function lockFromUpdate(uint256 _newLockFrom) public onlyAuthorized {
        lockFromBlock = _newLockFrom;
    }

    // Update the lockToBlock
    function lockToUpdate(uint256 _newLockTo) public onlyAuthorized {
        lockToBlock = _newLockTo;
    }

    /*
    function unlockedSupply() public view returns (uint256) {
        return totalSupply().sub(_totalLock);
    }
    */

    // 已解锁的量
    function unlockedSupply() public view returns (uint256) {
        return cap().sub(_totalLock);
    }

    // 总锁定量
    function lockedSupply() public view returns (uint256) {
        return totalLock();
    }
    // 流通量
    function circulatingSupply() public view returns (uint256) {
        return totalSupply();
    }

    // 总锁定量
    function totalLock() public view returns (uint256) {
        return _totalLock;
    }

    /**
     * @dev See {ERC20-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - minted tokens must not cause the total supply to go over the cap.
     * 铸造的代币不得导致总供应量超过上限。
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);

        if (from == address(0)) {
            // When minting tokens
            // require(
            //     totalSupply().add(amount) <= _cap,
            //     "ERC20Capped: cap exceeded"
            // );
            require(
                amount<= totalSupply(),
                "ERC20Capped: cap exceeded"
            );
        }
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
     /*
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override
    antiWhale(sender, recipient, amount)
    onlyProfile(sender, recipient) {
        super._transfer(sender, recipient, amount);
        _moveDelegates(_delegates[sender], _delegates[recipient], amount);
    }
    */

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override
    antiWhale(sender, recipient, amount) {
        super._transfer(sender, recipient, amount);
        _moveDelegates(_delegates[sender], _delegates[recipient], amount);
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterGardener).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
        _moveDelegates(address(0), _delegates[_to], _amount);
    }

    function manualMint(address _to, uint256 _amount) public onlyAuthorized {
        require(manualMinted < manualMintLimit, "ERC20: manualMinted greater than manualMintLimit");
        _mint(_to, _amount);
        _moveDelegates(address(0), _delegates[_to], _amount);
        manualMinted = manualMinted.add(_amount);
    }


    // 释放奖励
    /// @notice release `_amount` token to `_to`. Must only be called by the owner (MasterGardener).
    function releaseReward(address _to, uint256 _amount) public onlyOwner {
       _transfer(address(this),_to, _amount);
       _releasedCap = _releasedCap.add(_amount);
    }
    // 手动释放奖励
    function manualReleaseReward(address _to, uint256 _amount) public onlyAuthorized {
        require(manualReleased < manualReleaseLimit, "ERC20: manualMinted greater than manualMintLimit");

        uint256 restReward = cap().sub(_releasedCap);
        require(_amount > restReward, "ERC20: manualMinted greater than restReward");

       _transfer(address(this),_to, _amount);
        _releasedCap = _releasedCap.add(_amount);
        manualReleased = manualReleased.add(_amount);

    }

    // 用户总的余额
    function totalBalanceOf(address _holder) public view returns (uint256) {
        return _locks[_holder].add(balanceOf(_holder));
    }

    // 用户总的锁定量
    function lockOf(address _holder) public view returns (uint256) {
        return _locks[_holder];
    }

    // 上次解锁的块
    function lastUnlockBlock(address _holder) public view returns (uint256) {
        return _lastUnlockBlock[_holder];
    }

    // 锁定用户一定数量的token
    function lock(address _holder, uint256 _amount) public onlyAuthorized {
        require(_holder != address(0), "Cannot lock to the zero address");
        require(
            _amount <= balanceOf(_holder),
            "Lock amount over balance"
        );

        _transfer(_holder, address(this), _amount);

        _locks[_holder] = _locks[_holder].add(_amount);
        _totalLock = _totalLock.add(_amount);
        if (_lastUnlockBlock[_holder] < lockFromBlock) {
            _lastUnlockBlock[_holder] = lockFromBlock;
        }
        emit Lock(_holder, _amount);
    }
    // 用户可以解锁的数量
    function canUnlockAmount(address _holder) public view returns (uint256) {
        if (block.number < lockFromBlock) {
            return 0;
        } else if (block.number >= lockToBlock) {
            return _locks[_holder];
        } else {
            /*

            uint256 releaseBlock = block.number - _lastUnlockBlock[_holder]; // 释放的新块
            uint256 numberLockBlock = lockToBlock - _lastUnlockBlock[_holder]; // 还有多少未释放的块
            uint256 rate  = releaseBlock*(1e12)/numberLockBlock
            return _locks[_holder]* rate/(1e12)
            
             */
            uint256 releaseBlock = block.number.sub(_lastUnlockBlock[_holder]);
            uint256 numberLockBlock =
                lockToBlock.sub(_lastUnlockBlock[_holder]);
            return _locks[_holder].mul(releaseBlock).div(numberLockBlock);
        }
    }

    // Unlocks some locked tokens immediately.
    function unlockForUser(address account, uint256 amount) public onlyAuthorized {
        // First we need to unlock all tokens the address is eligible for.
        uint256 pendingLocked = canUnlockAmount(account);
        if (pendingLocked > 0) {
            _unlock(account, pendingLocked);
        }

        // Now that that's done, we can unlock the extra amount passed in.
        _unlock(account, amount);
    }
    // 解锁用户锁定的token数量
    function unlock() public {
        uint256 amount = canUnlockAmount(msg.sender);
        _unlock(msg.sender, amount);
    }

    function _unlock(address holder, uint256 amount) internal {
        require(_locks[holder] > 0, "Insufficient locked tokens");

        // Make sure they aren't trying to unlock more than they have locked.
        if (amount > _locks[holder]) {
            amount = _locks[holder];
        }

        // If the amount is greater than the total balance, set it to max.
        if (amount > balanceOf(address(this))) {
            amount = balanceOf(address(this));
        }
        // function _transfer(address sender,address recipient,uint256 amount) 
        // 向用户转账解锁的数量
        _transfer(address(this), holder, amount);
        // 减少用户锁定的数量
        _locks[holder] = _locks[holder].sub(amount);
        // 记录解锁的块
        _lastUnlockBlock[holder] = block.number;
        // 减少总的锁定量
        _totalLock = _totalLock.sub(amount);

        emit Unlock(holder, amount);
    }

    // This function is for dev address migrate all balance to a multi sig address
    // 此功能用于开发人员地址将所有余额迁移到多签名地址
    function transferAll(address _to) public {
        _locks[_to] = _locks[_to].add(_locks[msg.sender]);

        if (_lastUnlockBlock[_to] < lockFromBlock) {
            _lastUnlockBlock[_to] = lockFromBlock;
        }

        if (_lastUnlockBlock[_to] < _lastUnlockBlock[msg.sender]) {
            _lastUnlockBlock[_to] = _lastUnlockBlock[msg.sender];
        }

        _locks[msg.sender] = 0;
        _lastUnlockBlock[msg.sender] = 0;

        _transfer(msg.sender, _to, balanceOf(msg.sender));
    }

    // Copied and modified from YAM code:
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernanceStorage.sol
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernance.sol
    // Which is copied and modified from COMPOUND:
    // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol

    /// @dev A record of each accounts delegate
    mapping(address => address) internal _delegates;

    /// @notice A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @notice A record of votes checkpoints for each account, by index
    // 每个帐户的投票检查点记录，按索引
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;

    /// @notice The number of checkpoints for each account
    // 每个帐户的检查点数
    mapping(address => uint32) public numCheckpoints;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice A record of states for signing / validating signatures
    mapping(address => uint256) public nonces;

    /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );

    /// @notice An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(
        address indexed delegate,
        uint256 previousBalance,
        uint256 newBalance
    );

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator) external view returns (address) {
        return _delegates[delegator];
    }

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegatee The address to delegate votes to
     */
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator =
            keccak256(
                abi.encode(
                    DOMAIN_TYPEHASH,
                    keccak256(bytes(name())),
                    getChainId(),
                    address(this)
                )
            );

        bytes32 structHash =
            keccak256(
                abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry)
            );

        bytes32 digest =
            keccak256(
                abi.encodePacked("\x19\x01", domainSeparator, structHash)
            );

        address signatory = ecrecover(digest, v, r, s);
        require(
            signatory != address(0),
            "JewelToken::delegateBySig: invalid signature"
        );
        require(
            nonce == nonces[signatory]++,
            "JewelToken::delegateBySig: invalid nonce"
        );
        require(now <= expiry, "JewelToken::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return
            nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint256 blockNumber)
        external
        view
        returns (uint256)
    {
        require(
            blockNumber < block.number,
            "JewelToken::getPriorVotes: not yet determined"
        );

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(
        address srcRep,
        address dstRep,
        uint256 amount
    ) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld =
                    srcRepNum > 0
                        ? checkpoints[srcRep][srcRepNum - 1].votes
                        : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld =
                    dstRepNum > 0
                        ? checkpoints[dstRep][dstRepNum - 1].votes
                        : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    ) internal {
        uint32 blockNumber =
            safe32(
                block.number,
                "JewelToken::_writeCheckpoint: block number exceeds 32 bits"
            );

        if (
            nCheckpoints > 0 &&
            checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber
        ) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(
                blockNumber,
                newVotes
            );
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint256 n, string memory errorMessage)
        internal
        pure
        returns (uint32)
    {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    /**
     * @dev Update the max transfer amount rate.
     */
    function updateMaxTransferAmountRate(uint16 _maxTransferAmountRate) public onlyAuthorized {
        // 最大转账金额比例不得超过最大速率
        require(_maxTransferAmountRate <= 10000, "updateMaxTransferAmountRate: Max transfer amount rate must not exceed the maximum rate.");
        // 最大转账金额比例必须大于0.005
        require(_maxTransferAmountRate >= 50, "updateMaxTransferAmountRate: Max transfer amount rate must be more than 0.005.");
        emit MaxTransferAmountRateUpdated(maxTransferAmountRate, _maxTransferAmountRate);
        maxTransferAmountRate = _maxTransferAmountRate;
    }

    /**
     * @dev Calculates the max transfer amount.
     */
    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(10000);
    }

    /**
     * @dev Sets an address as excluded or not from the anti-whale checking.
     */
    function setExcludedFromAntiWhale(address _account, bool _excluded) public onlyAuthorized {
        _excludedFromAntiWhale[_account] = _excluded;
    }
}
