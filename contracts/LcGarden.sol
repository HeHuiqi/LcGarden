// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LcToken.sol";
import "./Authorizable.sol";

// MasterGardener is the master gardener of whatever gardens are available.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once JEWEL is sufficiently
// distributed and the community can show to govern itself.
//
contract MasterGardener is Ownable, Authorizable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // 用户提供了多少 LP 令牌
        uint256 rewardDebt; // 奖励债务。即用户已经领取的奖励数包括解锁和未解锁的数量，解锁的直接到钱包中，未解锁的锁定到了Token合约中并标记了所属用户
        uint256 rewardDebtAtBlock; // 最后一个区块用户权益，用户最近一次领取奖励的区块
        uint256 lastWithdrawBlock; // 用户提现的最后一个区块.
        uint256 firstDepositBlock; // 用户存入的第一个区块。
        uint256 blockdelta; // 自提现后经过的时间
        uint256 lastDepositBlock; //上一次存入的区块

        /*

        我们在这里做一些花哨的数学。 基本上，在任何时间点，授予用户但待分配的 JEWEL 数量为：
        待定奖励 = (user.amount * pool.accGovTokenPerShare) - user.rewardDebt

        每当用户将 LP 代币存入或提取到池中时。 这是发生的事情：
        1. 池的`accGovTokenPerShare`（和`lastRewardBlock`）得到更新。
        2. 用户收到发送到他/她地址的待定奖励。
        3. 用户的“amount”得到更新。
        4. 用户的`rewardDebt`得到更新。

        */

        //
        // We do some fancy math here. Basically, at any point in time, the
        // amount of JEWEL
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accGovTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGovTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    struct UserGlobalInfo {
        uint256 globalAmount;
        mapping(address => uint256) referrals;
        uint256 totalReferals;
        uint256 globalRefAmount;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // 分配给该池的分配点数。 JEWEL 按块分配。
        uint256 lastRewardBlock; // Last block number that JEWEL distribution occurs.
        // 每股累计宝石，乘以1e12。见下文
        // 当前一个LP能兑换多少个JEWEL token
        uint256 accGovTokenPerShare; // Accumulated JEWEL per share, times 1e12. See below.
    }

    // The Lc token
    LcToken public govToken;
    //An ETH/USDC Oracle (Chainlink)
    address public usdOracle;
    // Dev address.
    address public devaddr;
    // LP address
    address public liquidityaddr;
    // Community Fund Address
    address public comfundaddr;
    // Founder Reward
    address public founderaddr;
    // JEWEL created per block.
    uint256 public REWARD_PER_BLOCK;
    // Bonus multiplier for early JEWEL makers.
    uint256[] public REWARD_MULTIPLIER; // init in constructor function
    // 减半block halving
    uint256[] public HALVING_AT_BLOCK; // init in constructor function 当前102
    uint256[] public blockDeltaStartStage;
    uint256[] public blockDeltaEndStage;
    uint256[] public userFeeStage; // [0~7] 用户提前提现手续费率 从 0.01% 到 25%
    uint256[] public devFeeStage; // [0-7]; 提现是给开发者的手续费
    uint256 public FINISH_BONUS_AT_BLOCK; // 结束区块
    uint256 public userDepFee;
    uint256 public devDepFee;

    // The block number when JEWEL mining starts.
    uint256 public START_BLOCK; // 开始区块

    uint256[] public PERCENT_LOCK_BONUS_REWARD; // lock xx% of bounus reward 当前index36+以上都是4
    uint256 public PERCENT_FOR_DEV; // dev bounties
    uint256 public PERCENT_FOR_LP; // LP fund
    uint256 public PERCENT_FOR_COM; // community fund
    uint256 public PERCENT_FOR_FOUNDERS; // founders fund

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // poolId1 从 1 开始，与 poolInfo 一起使用前减去 1
    // LP池子ID，JEWEL/ONE_id=1
    mapping(address => uint256) public poolId1; // poolId1 starting from 1, subtract 1 before using with poolInfo

    // 每个持有 LP 代币的用户的信息。pid => user address => info
    // Info of each user that stakes LP tokens. pid => user address => info
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    mapping(address => UserGlobalInfo) public userGlobalInfo;
    mapping(IERC20 => bool) public poolExistence;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    // 总分配额。必须是所有池中所有分配点的总和
    uint256 public totalAllocPoint = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event SendGovernanceTokenReward(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 lockAmount
    );

    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "MasterGardener::nonDuplicated: duplicated");
        _;
    }


  constructor(
        LcToken _govToken,
        address _devaddr,
        uint256 _halvingAfterBlock,
        uint256 _startBlock
    ) public {
        govToken = _govToken;
        devaddr = _devaddr;
        liquidityaddr = _devaddr;
        comfundaddr = _devaddr;
        founderaddr = _devaddr;

        REWARD_PER_BLOCK = 1e18;

        START_BLOCK = _startBlock;

        userDepFee = 0;
        devDepFee = 0;

        uint256[36] memory  _rewardMultiplier = [uint256(256),128,96,64,56,48,40,32,28,24,20,16,15,14,13,12,11,10,9,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,4];
        REWARD_MULTIPLIER = _rewardMultiplier;
        uint256[8] memory _blockDeltaStartStage = [uint256(0),1,1771,43201,129601,216001,604801,1209601];
        blockDeltaStartStage = _blockDeltaStartStage;
        uint256[6] memory _blockDeltaEndStage = [uint256(1770),43200,129600,216000,604800,1209600];
        blockDeltaEndStage = _blockDeltaEndStage;

        uint256[8] memory _userFeeStage = [uint256(75),92,96,98,99,995,9975,9999];
        userFeeStage = _userFeeStage;

        uint256[8] memory _devFeeStage = [uint256(75),92,96,98,99,995,9975,9999];
        devFeeStage = _devFeeStage;

        // 302400*1+startblcok+1
        for (uint256 i = 0; i < REWARD_MULTIPLIER.length - 1; i++) {
            uint256 halvingAtBlock = _halvingAfterBlock.mul(i+1).add(_startBlock).add(1);
            HALVING_AT_BLOCK.push(halvingAtBlock);
        }
        FINISH_BONUS_AT_BLOCK = _halvingAfterBlock
            .mul(REWARD_MULTIPLIER.length - 1)
            .add(_startBlock);
        HALVING_AT_BLOCK.push(uint256(-1));
    }
    /*
    constructor(
        LcToken _govToken,
        address _devaddr,
        address _liquidityaddr,
        address _comfundaddr,
        address _founderaddr,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _halvingAfterBlock,
        uint256 _userDepFee,
        uint256 _devDepFee,
        uint256[] memory _rewardMultiplier,
        uint256[] memory _blockDeltaStartStage,
        uint256[] memory _blockDeltaEndStage,
        uint256[] memory _userFeeStage,
        uint256[] memory _devFeeStage
    ) public {
        govToken = _govToken;
        devaddr = _devaddr;
        liquidityaddr = _liquidityaddr;
        comfundaddr = _comfundaddr;
        founderaddr = _founderaddr;
        REWARD_PER_BLOCK = _rewardPerBlock;
        START_BLOCK = _startBlock;
        userDepFee = _userDepFee;
        devDepFee = _devDepFee;
        REWARD_MULTIPLIER = _rewardMultiplier;
        blockDeltaStartStage = _blockDeltaStartStage;
        blockDeltaEndStage = _blockDeltaEndStage;
        userFeeStage = _userFeeStage;
        devFeeStage = _devFeeStage;
        // 302400*1+startblcok+1
        for (uint256 i = 0; i < REWARD_MULTIPLIER.length - 1; i++) {
            uint256 halvingAtBlock = _halvingAfterBlock.mul(i+1).add(_startBlock).add(1);
            HALVING_AT_BLOCK.push(halvingAtBlock);
        }
        FINISH_BONUS_AT_BLOCK = _halvingAfterBlock
            .mul(REWARD_MULTIPLIER.length - 1)
            .add(_startBlock);
        HALVING_AT_BLOCK.push(uint256(-1));
    }
    */

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(
            poolId1[address(_lpToken)] == 0,
            "MasterGardener::add: lp is already in pool"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            block.number > START_BLOCK ? block.number : START_BLOCK;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolId1[address(_lpToken)] = poolInfo.length + 1;
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accGovTokenPerShare: 0
            })
        );
    }

    // Update the given pool's JEWEL allocation points. Can only be called by the owner.
    // 更新给定池的 JEWEL 分配点数
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 GovTokenForDev;
        uint256 GovTokenForFarmer;
        uint256 GovTokenForLP;
        uint256 GovTokenForCom;
        uint256 GovTokenForFounders;
        (
            GovTokenForDev,
            GovTokenForFarmer,
            GovTokenForLP,
            GovTokenForCom,
            GovTokenForFounders
        ) = getPoolReward(pool.lastRewardBlock, block.number, pool.allocPoint);
        // Mint some new JEWEL tokens for the farmer and store them in MasterGardener.
        // 为农场主铸造一些新的JEWEL令牌，并将它们存储在MasterGardener中
        // govToken.mint(address(this), GovTokenForFarmer);
        govToken.releaseReward(address(this),GovTokenForFarmer);
        // pool.accGovTokenPerShare  = pool.accGovTokenPerShare + (GovTokenForFarmer * 1e12 /lpSupply)
        // 当前一个LP能兑换多少个JEWEL token
        pool.accGovTokenPerShare = pool.accGovTokenPerShare.add(
            GovTokenForFarmer.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
        if (GovTokenForDev > 0) {
            // govToken.mint(address(devaddr), GovTokenForDev);
            govToken.releaseReward(address(devaddr), GovTokenForDev);

            //Dev fund has xx% locked during the starting bonus period. After which locked funds drip out linearly each block over 3 years.
            // 开发基金在初始奖金期间锁定了xx%。之后，锁定的资金在3年内线性滴出每个区块。

            if (block.number <= FINISH_BONUS_AT_BLOCK) {
                govToken.lock(address(devaddr), GovTokenForDev.mul(75).div(100));
            }
        }
        if (GovTokenForLP > 0) {
            // govToken.mint(liquidityaddr, GovTokenForLP);
            govToken.releaseReward(liquidityaddr, GovTokenForLP);
            //LP + Partnership fund has only xx% locked over time as most of it is needed early on for incentives and listings. The locked amount will drip out linearly each block after the bonus period.
            // LP + Partnership基金随着时间的推移只有xx%锁定，因为其中大部分资金在早期就需要用于激励和上市。锁定金额将在奖金期后线性滴出每个区块。
            if (block.number <= FINISH_BONUS_AT_BLOCK) {
                govToken.lock(address(liquidityaddr), GovTokenForLP.mul(45).div(100));
            }
        }
        if (GovTokenForCom > 0) {
            // govToken.mint(comfundaddr, GovTokenForCom);
            govToken.releaseReward(comfundaddr, GovTokenForCom);
            //Community Fund has xx% locked during bonus period and then drips out linearly.
            // 社区基金在奖金期间锁定了xx%，然后线性滴出。
            if (block.number <= FINISH_BONUS_AT_BLOCK) {
                govToken.lock(address(comfundaddr), GovTokenForCom.mul(85).div(100));
            }
        }
        if (GovTokenForFounders > 0) {
            // govToken.mint(founderaddr, GovTokenForFounders);
            govToken.releaseReward(founderaddr, GovTokenForFounders);
            //The Founders reward has xx% of their funds locked during the bonus period which then drip out linearly.
            // 创始人奖励在奖金期间锁定了xx%的资金，然后线性滴出。
            if (block.number <= FINISH_BONUS_AT_BLOCK) {
                govToken.lock(address(founderaddr), GovTokenForFounders.mul(95).div(100));
            }
        }
    }

    // |--------------------------------------|
    // [20, 30, 40, 50, 60, 70, 80, 99999999]
    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 result = 0;
        if (_from < START_BLOCK) return 0;

        for (uint256 i = 0; i < HALVING_AT_BLOCK.length; i++) {
            uint256 endBlock = HALVING_AT_BLOCK[i];
            if (i > REWARD_MULTIPLIER.length-1) return 0;

            if (_to <= endBlock) {
                uint256 m = _to.sub(_from).mul(REWARD_MULTIPLIER[i]);
                return result.add(m);
            }

            if (_from < endBlock) {
                uint256 m = endBlock.sub(_from).mul(REWARD_MULTIPLIER[i]);
                _from = endBlock;
                result = result.add(m);
            }
        }

        return result;
    }

    // 获取当前锁定百分比
    function getLockPercentage(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 result = 0;
        if (_from < START_BLOCK) return 100;
        // HALVING_AT_BLOCK max  index 103
        for (uint256 i = 0; i < HALVING_AT_BLOCK.length; i++) {
            uint256 endBlock = HALVING_AT_BLOCK[i];
            if (i > PERCENT_LOCK_BONUS_REWARD.length-1) return 0;

            if (_to <= endBlock) {
                //PERCENT_LOCK_BONUS_REWARD max index 47
                return PERCENT_LOCK_BONUS_REWARD[i];
            }
        }

        return result;
    }

    function getPoolReward(
        uint256 _from,
        uint256 _to,
        uint256 _allocPoint
    )
        public
        view
        returns (
            uint256 forDev,
            uint256 forFarmer,
            uint256 forLP,
            uint256 forCom,
            uint256 forFounders
        )
    {
        uint256 multiplier = getMultiplier(_from, _to);

        // 获取块奖励数量
        uint256 amount =
            multiplier.mul(REWARD_PER_BLOCK).mul(_allocPoint).div(
                totalAllocPoint
            );
        /*
        // 计算还可以挖矿的JEWEL币的数量
        uint256 GovernanceTokenCanMint = govToken.cap().sub(govToken.totalSupply());
        // 如果剩余可挖的数据小于块奖励的数量
        if (GovernanceTokenCanMint < amount) {
            // If there aren't enough governance tokens left to mint before the cap,
            // just give all of the possible tokens left to the farmer.
            // 如果在上限之前没有足够的治理代币可供铸造，只需将所有可能的代币留给农民即可。
            forDev = 0;
            forFarmer = GovernanceTokenCanMint;
            forLP = 0;
            forCom = 0;
            forFounders = 0;
        } else {
            // Otherwise, give the farmer their full amount and also give some
            // extra to the dev, LP, com, and founders wallets.
            forDev = amount.mul(PERCENT_FOR_DEV).div(100);
            forFarmer = amount;
            forLP = amount.mul(PERCENT_FOR_LP).div(100);
            forCom = amount.mul(PERCENT_FOR_COM).div(100);
            forFounders = amount.mul(PERCENT_FOR_FOUNDERS).div(100);
        }
        */
             // 如果剩余奖励的数据小于块奖励的数量
        uint256 GovernanceTokenCanRelease = govToken.cap().sub(govToken.releasedCap());
        if (GovernanceTokenCanRelease < amount) {
            // 如果在上限之前没有足够的治理代币可供释放，只需将所有可能的代币留给农民即可。
            forDev = 0;
            forFarmer = GovernanceTokenCanRelease;
            forLP = 0;
            forCom = 0;
            forFounders = 0;
        } else {
            // Otherwise, give the farmer their full amount and also give some
            // extra to the dev, LP, com, and founders wallets.
            forDev = amount.mul(PERCENT_FOR_DEV).div(100);
            forFarmer = amount;
            forLP = amount.mul(PERCENT_FOR_LP).div(100);
            forCom = amount.mul(PERCENT_FOR_COM).div(100);
            forFounders = amount.mul(PERCENT_FOR_FOUNDERS).div(100);
        }

    }

    // View function to see pending JEWEL on frontend.
    // 查询用户在某个池子的获取的奖励（从当前块到上一次奖励的块），通过 getLockPercentage(block.number-1,block.number) 可以获取当前锁定的百分比
    // 从而可以计算出用户奖励的锁定和解锁的token数量
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        // 获取池子占比
        uint256 accGovTokenPerShare = pool.accGovTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply > 0) {
            uint256 GovTokenForFarmer;
            (, GovTokenForFarmer, , , ) = getPoolReward(
                pool.lastRewardBlock,
                block.number,
                pool.allocPoint
            );
            // 计算当前一个LP值多少挖出的JEWEL，相当于 1LP = accGovTokenPerShare JEWEL
            accGovTokenPerShare = accGovTokenPerShare.add(
                GovTokenForFarmer.mul(1e12).div(lpSupply)
            );
        }
        // 更具自己质押的计算自己收益
        return user.amount.mul(accGovTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    // 收取多个池子的奖励，已解锁的部分
    function claimRewards(uint256[] memory _pids) public {
        for (uint256 i = 0; i < _pids.length; i++) {
          claimReward(_pids[i]);
        }
    }

    // 收取奖励一个池子的奖励
    function claimReward(uint256 _pid) public {
        updatePool(_pid);
        _harvest(_pid);
    }

    // lock a % of reward if it comes from bonus time.
    // 锁定奖励的百分比（如果它来自奖励时间）
    function _harvest(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Only harvest if the user amount is greater than 0.
        if (user.amount > 0) {
            // Calculate the pending reward. This is the user's amount of LP
            // tokens multiplied by the accGovTokenPerShare of the pool, minus
            // the user's rewardDebt.
            // pending = user.amount * pool.accGovTokenPerShare/(1e12) - user.rewardDebt
            uint256 pending = 
                user.amount.mul(pool.accGovTokenPerShare).div(1e12).sub(
                    user.rewardDebt
                );

            // Make sure we aren't giving more tokens than we have in the
            // MasterGardener contract.
            uint256 masterBal = govToken.balanceOf(address(this));

            if (pending > masterBal) {
                pending = masterBal;
            }

            if (pending > 0) {
                // If the user has a positive pending balance of tokens, transfer
                // those tokens from MasterGardener to their wallet.
                // 如果用户有正的待处理token余额，请将这些token从MasterGardener转移到他们的钱包

                // function transfer ( address recipient, uint256 amount ) external returns ( bool );
                govToken.transfer(msg.sender, pending);
                uint256 lockAmount = 0;
                if (user.rewardDebtAtBlock <= FINISH_BONUS_AT_BLOCK) {
                    // If we are before the FINISH_BONUS_AT_BLOCK number, we need
                    // to lock some of those tokens, based on the current lock
                    // percentage of their tokens they just received.
                    uint256 lockPercentage = getLockPercentage(block.number - 1, block.number);
                    lockAmount = pending.mul(lockPercentage).div(100);
                    govToken.lock(msg.sender, lockAmount);
                }

                // Reset the rewardDebtAtBlock to the current block for the user.
                user.rewardDebtAtBlock = block.number;

                emit SendGovernanceTokenReward(msg.sender, _pid, pending, lockAmount);
            }

            // Recalculate the rewardDebt for the user.
            user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(1e12);
        }
    }

    function getGlobalAmount(address _user) public view returns (uint256) {
        UserGlobalInfo memory current = userGlobalInfo[_user];
        return current.globalAmount;
    }

    function getGlobalRefAmount(address _user) public view returns (uint256) {
        UserGlobalInfo memory current = userGlobalInfo[_user];
        return current.globalRefAmount;
    }

    function getTotalRefs(address _user) public view returns (uint256) {
        UserGlobalInfo memory current = userGlobalInfo[_user];
        return current.totalReferals;
    }

    function getRefValueOf(address _user, address _user2) public view returns (uint256) {
        UserGlobalInfo storage current = userGlobalInfo[_user];
        uint256 a = current.referrals[_user2];
        return a;
    }

    // Deposit LP tokens to MasterGardener for JEWEL allocation.
    // 存入LP token
    // pid = poolid 从1开始，但是下标从 0 开始
    // 指定poolId存入LP
    // JEWEL/ONE_token =  LP, id 为1-1 = 0
    function deposit(uint256 _pid, uint256 _amount, address _ref) public nonReentrant {
        require(
            _amount > 0,
            "MasterGardener::deposit: amount must be greater than 0"
        );

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        // devaddr: dev address
        UserInfo storage devr = userInfo[_pid][devaddr];
        UserGlobalInfo storage refer = userGlobalInfo[_ref];
        UserGlobalInfo storage current = userGlobalInfo[msg.sender];

        if (refer.referrals[msg.sender] > 0) {
            refer.referrals[msg.sender] = refer.referrals[msg.sender] + _amount;
            refer.globalRefAmount = refer.globalRefAmount + _amount;
        } else {
            refer.referrals[msg.sender] = refer.referrals[msg.sender] + _amount;
            refer.totalReferals = refer.totalReferals + 1;
            refer.globalRefAmount = refer.globalRefAmount + _amount;
        }
        // userDepFee 用户调试费
        current.globalAmount =
            current.globalAmount +
            _amount.mul(userDepFee).div(100);

        // When a user deposits, we need to update the pool and harvest beforehand,
        // since the rates will change.
        // 当用户存款时，我们需要事先更新池并收获，因为费率会发生变化。即将之情的收益结算一下
        updatePool(_pid);
        _harvest(_pid);

        // 向此合约转账LP，保存用户的LP
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        if (user.amount == 0) {
            // 如果是第一次存入则记录用户存入是的block number
            user.rewardDebtAtBlock = block.number;
        }

        // 减去用户的调试费就是此次存入的真实LP数量
        user.amount = user.amount.add(
            _amount.sub(_amount.mul(userDepFee).div(10000))
        );
        // user.rewardDebt =  user.amount * pool.accGovTokenPerShare / 1e12
        user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(1e12);
        devr.amount = devr.amount.add(
            _amount.sub(_amount.mul(devDepFee).div(10000))
        );
        // devr.rewardDebt =  devr.amount * pool.accGovTokenPerShare / 1e12
        devr.rewardDebt = devr.amount.mul(pool.accGovTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
        if (user.firstDepositBlock > 0) {} else {
            user.firstDepositBlock = block.number;
        }
        user.lastDepositBlock = block.number;
    }

    // Withdraw LP tokens from MasterGardener.
    // 提现LP token
    function withdraw(uint256 _pid, uint256 _amount, address _ref) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        UserGlobalInfo storage refer = userGlobalInfo[_ref];
        UserGlobalInfo storage current = userGlobalInfo[msg.sender];
        require(user.amount >= _amount, "MasterGardener::withdraw: not good");
        if (_ref != address(0)) {
            refer.referrals[msg.sender] = refer.referrals[msg.sender] - _amount;
            refer.globalRefAmount = refer.globalRefAmount - _amount;
        }
        current.globalAmount = current.globalAmount - _amount;
        // 结算收益
        updatePool(_pid);
        _harvest(_pid);
        // 开始提现，根据相应条件来收取手续费
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            if (user.lastWithdrawBlock > 0) {
                user.blockdelta = block.number - user.lastWithdrawBlock;
            } else {
                user.blockdelta = block.number - user.firstDepositBlock;
            }
            if (
                user.blockdelta == blockDeltaStartStage[0] ||
                block.number == user.lastDepositBlock
            ) {
                //25% fee for withdrawals of LP tokens in the same block this is to prevent abuse from flashloans
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[0]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[0]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[1] &&
                user.blockdelta <= blockDeltaEndStage[0]
            ) {
                //8% fee if a user deposits and withdraws in between same block and 59 minutes.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[1]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[1]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[2] &&
                user.blockdelta <= blockDeltaEndStage[1]
            ) {
                //4% fee if a user deposits and withdraws after 1 hour but before 1 day.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[2]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[2]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[3] &&
                user.blockdelta <= blockDeltaEndStage[2]
            ) {
                //2% fee if a user deposits and withdraws between after 1 day but before 3 days.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[3]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[3]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[4] &&
                user.blockdelta <= blockDeltaEndStage[3]
            ) {
                //1% fee if a user deposits and withdraws after 3 days but before 5 days.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[4]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[4]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[5] &&
                user.blockdelta <= blockDeltaEndStage[4]
            ) {
                //0.5% fee if a user deposits and withdraws if the user withdraws after 5 days but before 2 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[5]).div(1000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[5]).div(1000)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[6] &&
                user.blockdelta <= blockDeltaEndStage[5]
            ) {
                //0.25% fee if a user deposits and withdraws after 2 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[6]).div(10000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[6]).div(10000)
                );
            } else if (user.blockdelta > blockDeltaStartStage[7]) {
                //0.1% fee if a user deposits and withdraws after 4 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[7]).div(10000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[7]).div(10000)
                );
            }
            user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(1e12);
            emit Withdraw(msg.sender, _pid, _amount);
            user.lastWithdrawBlock = block.number;
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY. This has the same 25% fee as same block withdrawals to prevent abuse of thisfunction.
    // 紧急提现，扣取25%的罚金
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        //reordered from Sushi function to prevent risk of reentrancy
        uint256 amountToSend = user.amount.mul(75).div(100);
        uint256 devToSend = user.amount.mul(25).div(100);
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amountToSend);
        pool.lpToken.safeTransfer(address(devaddr), devToSend);
        emit EmergencyWithdraw(msg.sender, _pid, amountToSend);
    }

    // Safe GovToken transfer function, just in case if rounding error causes pool to not have enough GovTokens.
    function safeGovTokenTransfer(address _to, uint256 _amount) internal {
        uint256 govTokenBal = govToken.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > govTokenBal) {
            transferSuccess = govToken.transfer(_to, govTokenBal);
        } else {
            transferSuccess = govToken.transfer(_to, _amount);
        }
        require(transferSuccess, "MasterGardener::safeGovTokenTransfer: transfer failed");
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public onlyAuthorized {
        devaddr = _devaddr;
    }

    // Update Finish Bonus Block
    function bonusFinishUpdate(uint256 _newFinish) public onlyAuthorized {
        FINISH_BONUS_AT_BLOCK = _newFinish;
    }

    // Update Halving At Block
    function halvingUpdate(uint256[] memory _newHalving) public onlyAuthorized {
        HALVING_AT_BLOCK = _newHalving;
    }

    // Update Liquidityaddr
    function lpUpdate(address _newLP) public onlyAuthorized {
        liquidityaddr = _newLP;
    }

    // Update comfundaddr
    function comUpdate(address _newCom) public onlyAuthorized {
        comfundaddr = _newCom;
    }

    // Update founderaddr
    function founderUpdate(address _newFounder) public onlyAuthorized {
        founderaddr = _newFounder;
    }

    // Update Reward Per Block
    function rewardUpdate(uint256 _newReward) public onlyAuthorized {
        REWARD_PER_BLOCK = _newReward;
    }

    // Update Rewards Mulitplier Array
    function rewardMulUpdate(uint256[] memory _newMulReward) public onlyAuthorized {
        REWARD_MULTIPLIER = _newMulReward;
    }

    // Update % lock for general users
    function lockUpdate(uint256[] memory _newlock) public onlyAuthorized {
        PERCENT_LOCK_BONUS_REWARD = _newlock;
    }

    // Update % lock for dev
    function lockdevUpdate(uint256 _newdevlock) public onlyAuthorized {
        PERCENT_FOR_DEV = _newdevlock;
    }

    // Update % lock for LP
    function locklpUpdate(uint256 _newlplock) public onlyAuthorized {
        PERCENT_FOR_LP = _newlplock;
    }

    // Update % lock for COM
    function lockcomUpdate(uint256 _newcomlock) public onlyAuthorized {
        PERCENT_FOR_COM = _newcomlock;
    }

    // Update % lock for Founders
    function lockfounderUpdate(uint256 _newfounderlock) public onlyAuthorized {
        PERCENT_FOR_FOUNDERS = _newfounderlock;
    }

    // Update START_BLOCK
    function starblockUpdate(uint256 _newstarblock) public onlyAuthorized {
        START_BLOCK = _newstarblock;
    }

    // 获取一个block最新的奖励
    function getNewRewardPerBlock(uint256 pid1) public view returns (uint256) {
        uint256 multiplier = getMultiplier(block.number - 1, block.number);
        if (pid1 == 0) {
            return multiplier.mul(REWARD_PER_BLOCK);
        } else {
            return
                multiplier
                    .mul(REWARD_PER_BLOCK)
                    .mul(poolInfo[pid1 - 1].allocPoint)
                    .div(totalAllocPoint);
        }
    }
    // 获取用户上次提现后的块之后到当前又产生了多少块
    function userDelta(uint256 _pid) public view returns (uint256) {
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.lastWithdrawBlock > 0) {
            uint256 estDelta = block.number - user.lastWithdrawBlock;
            return estDelta;
        } else {
            uint256 estDelta = block.number - user.firstDepositBlock;
            return estDelta;
        }
    }

    // 修正提现块
    function reviseWithdraw(uint256 _pid, address _user, uint256 _block) public onlyAuthorized() {
        UserInfo storage user = userInfo[_pid][_user];
        user.lastWithdrawBlock = _block;
    }

    // 修正存入块
    function reviseDeposit(uint256 _pid, address _user, uint256 _block) public onlyAuthorized() {
        UserInfo storage user = userInfo[_pid][_user];
        user.firstDepositBlock = _block;
    }

    function setStageStarts(uint256[] memory _blockStarts) public onlyAuthorized() {
        blockDeltaStartStage = _blockStarts;
    }

    function setStageEnds(uint256[] memory _blockEnds) public onlyAuthorized() {
        blockDeltaEndStage = _blockEnds;
    }

    function setUserFeeStage(uint256[] memory _userFees) public onlyAuthorized() {
        userFeeStage = _userFees;
    }

    function setDevFeeStage(uint256[] memory _devFees) public onlyAuthorized() {
        devFeeStage = _devFees;
    }

    function setDevDepFee(uint256 _devDepFees) public onlyAuthorized() {
        devDepFee = _devDepFees;
    }

    function setUserDepFee(uint256 _usrDepFees) public onlyAuthorized() {
        userDepFee = _usrDepFees;
    }
    // 返还token的owner权限
    function reclaimTokenOwnership(address _newOwner) public onlyAuthorized() {
        govToken.transferOwnership(_newOwner);
    }

    // 对Garden Owner权限的测试
    function deledateMint(address account, uint256 amount) public onlyOwner{
        govToken.mint(account,amount);
    }

        // 对Garden Owner权限的测试
    function deledateReleaseReward(address account, uint256 amount) public onlyOwner {
        govToken.releaseReward(account,amount);
    }
}
