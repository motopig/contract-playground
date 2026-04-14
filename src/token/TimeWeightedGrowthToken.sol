// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "forge-std/Test.sol";

/**
 * @title TimeWeightedGrowthToken
 * @dev 基于时间加权的自增长代币合约
 *
 * 特性：
 * 1. 持有时间越长，累积的收益越多
 * 2. 支持动态调整年化收益率
 * 3. 复利计算机制
 * 4. 转账时自动结算收益
 */
contract TimeWeightedGrowthToken is ERC20, Ownable, ReentrancyGuard {
    // ============ 状态变量 ============

    /// @notice 年化收益率 (basis points, 10000 = 100%)
    /// 例如: 500 = 5%, 1000 = 10%
    uint256 public annualYieldRate;

    /// @notice 每个地址的最后更新时间
    mapping(address => uint256) public lastUpdateTime;

    /// @notice 每个地址的累积未提取收益
    mapping(address => uint256) public accruedRewards;

    /// @notice 时间加权系数配置
    struct WeightConfig {
        uint256 threshold; // 时间阈值（秒）
        uint256 multiplier; // 收益倍数 (basis points)
    }

    /// @notice 时间加权配置数组
    WeightConfig[] public weightConfigs;

    /// @notice 最大供应量
    uint256 public maxSupply;

    /// @notice 是否启用增长机制
    bool public growthEnabled;

    // ============ 事件 ============

    event YieldRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardsClaimed(address indexed user, uint256 amount);
    event WeightConfigUpdated(uint256 index, uint256 threshold, uint256 multiplier);
    event GrowthToggled(bool enabled);
    event MaxSupplyUpdated(uint256 newMaxSupply);

    // ============ 构造函数 ============

    constructor(string memory _name, string memory _symbol, uint256 _annualYieldRate, uint256 _maxSupply)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        require(_annualYieldRate <= 10000, "Rate too high"); // 最大100%
        annualYieldRate = _annualYieldRate;
        maxSupply = _maxSupply;
        growthEnabled = true;

        // 初始化默认时间加权配置
        // 持有 < 30天: 1.0x
        weightConfigs.push(WeightConfig({threshold: 30 days, multiplier: 10000}));

        // 持有 30-90天: 1.2x
        weightConfigs.push(WeightConfig({threshold: 90 days, multiplier: 12000}));

        // 持有 90-180天: 1.5x
        weightConfigs.push(WeightConfig({threshold: 180 days, multiplier: 15000}));

        // 持有 > 180天: 2.0x
        weightConfigs.push(WeightConfig({threshold: type(uint256).max, multiplier: 20000}));
    }

    // ============ 核心函数 ============

    /**
     * @notice 计算用户当前的总余额（包括未提取收益）
     * @param _account 用户地址
     * @return 总余额
     */
    function balanceOf(address _account) public view override returns (uint256) {
        uint256 baseBalance_ = super.balanceOf(_account);
        uint256 pendingRewards_ = _calculatePendingRewards(_account);
        return baseBalance_ + accruedRewards[_account] + pendingRewards_;
    }

    /**
     * @notice 计算待领取的收益
     * @param _account 用户地址
     * @return 待领取收益
     */
    function pendingRewards(address _account) external view returns (uint256) {
        return _calculatePendingRewards(_account);
    }

    /**
     * @notice 内部函数：计算待领取收益
     */
    function _calculatePendingRewards(address _account) internal view returns (uint256) {
        if (!growthEnabled || lastUpdateTime[_account] == 0) {
            return 0;
        }

        uint256 baseBalance_ = super.balanceOf(_account);
        if (baseBalance_ == 0) {
            return 0;
        }

        uint256 timeElapsed_ = block.timestamp - lastUpdateTime[_account];
        uint256 holdingDuration_ = timeElapsed_;

        // 获取时间加权倍数
        uint256 weightMultiplier_ = _getWeightMultiplier(holdingDuration_);

        // 计算收益: 本金 * 年化率 * 时间系数 * 加权倍数
        // rewards_ = principal * rate * (timeElapsed_ / 365 days) * multiplier
        uint256 rewards_ =
            (baseBalance_ * annualYieldRate * timeElapsed_ * weightMultiplier_) / (10000 * 365 days * 10000);

        return rewards_;
    }

    /**
     * @notice 获取时间加权倍数
     * @param _duration 持有时长（秒）
     * @return 加权倍数
     */
    function _getWeightMultiplier(uint256 _duration) internal view returns (uint256) {
        for (uint256 i_ = 0; i_ < weightConfigs.length; i_++) {
            if (_duration <= weightConfigs[i_].threshold) {
                return weightConfigs[i_].multiplier;
            }
        }
        return 10000; // 默认1.0x
    }

    /**
     * @notice 更新用户收益
     */
    function _updateRewards(address _account) internal {
        if (_account == address(0)) {
            return;
        }

        uint256 pending_ = _calculatePendingRewards(_account);
        if (pending_ > 0) {
            accruedRewards[_account] += pending_;
        }
        lastUpdateTime[_account] = block.timestamp;
    }

    /**
     * @notice 领取收益
     */
    function claimRewards() external nonReentrant {
        _updateRewards(msg.sender);

        uint256 rewards_ = accruedRewards[msg.sender];
        require(rewards_ > 0, "No rewards to claim");

        accruedRewards[msg.sender] = 0;

        // 检查最大供应量
        require(totalSupply() + rewards_ <= maxSupply, "Exceeds max supply");

        _mint(msg.sender, rewards_);

        emit RewardsClaimed(msg.sender, rewards_);
    }

    /**
     * @notice 手动触发收益更新
     */
    function updateMyRewards() external {
        _updateRewards(msg.sender);
    }

    // ============ 重写转账函数 ============

    /**
     * @dev 转账前更新双方收益
     */
    function _update(address _from, address _to, uint256 _amount) internal virtual override {
        _updateRewards(_from);
        _updateRewards(_to);
        super._update(_from, _to, _amount);
    }

    // ============ Mint 和 Burn ============

    /**
     * @notice 铸造代币
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(totalSupply() + _amount <= maxSupply, "Exceeds max supply");
        _mint(_to, _amount);
        lastUpdateTime[_to] = block.timestamp;
    }

    /**
     * @notice 销毁代币
     */
    function burn(uint256 _amount) external {
        _updateRewards(msg.sender);
        _burn(msg.sender, _amount);
    }

    // ============ 管理员函数 ============

    /**
     * @notice 更新年化收益率
     */
    function setAnnualYieldRate(uint256 _newRate) external onlyOwner {
        require(_newRate <= 10000, "Rate too high");
        uint256 oldRate_ = annualYieldRate;
        annualYieldRate = _newRate;
        emit YieldRateUpdated(oldRate_, _newRate);
    }

    /**
     * @notice 更新时间加权配置
     */
    function setWeightConfig(uint256 _index, uint256 _threshold, uint256 _multiplier) external onlyOwner {
        require(_index < weightConfigs.length, "Invalid index");
        require(_multiplier >= 10000 && _multiplier <= 50000, "Invalid multiplier");

        weightConfigs[_index] = WeightConfig({threshold: _threshold, multiplier: _multiplier});

        emit WeightConfigUpdated(_index, _threshold, _multiplier);
    }

    /**
     * @notice 添加新的时间加权配置
     */
    function addWeightConfig(uint256 _threshold, uint256 _multiplier) external onlyOwner {
        require(_multiplier >= 10000 && _multiplier <= 50000, "Invalid multiplier");
        weightConfigs.push(WeightConfig({threshold: _threshold, multiplier: _multiplier}));
    }

    /**
     * @notice 启用/禁用增长机制
     */
    function toggleGrowth(bool _enabled) external onlyOwner {
        growthEnabled = _enabled;
        emit GrowthToggled(_enabled);
    }

    /**
     * @notice 更新最大供应量
     */
    function setMaxSupply(uint256 _newMaxSupply) external onlyOwner {
        require(_newMaxSupply >= totalSupply(), "Below current supply");
        maxSupply = _newMaxSupply;
        emit MaxSupplyUpdated(_newMaxSupply);
    }

    // ============ 查询函数 ============

    /**
     * @notice 获取时间加权配置数量
     */
    function getWeightConfigCount() external view returns (uint256) {
        return weightConfigs.length;
    }

    /**
     * @notice 获取用户的实际余额（不含收益）
     */
    function getActualBalance(address _account) external view returns (uint256) {
        return super.balanceOf(_account);
    }

    /**
     * @notice 获取用户完整信息
     */
    function getUserInfo(address _account)
        external
        view
        returns (
            uint256 actualBalance_,
            uint256 accruedAmount_,
            uint256 pendingAmount_,
            uint256 totalBalance_,
            uint256 lastUpdate_,
            uint256 holdingDuration_
        )
    {
        actualBalance_ = super.balanceOf(_account);
        accruedAmount_ = accruedRewards[_account];
        pendingAmount_ = _calculatePendingRewards(_account);
        totalBalance_ = actualBalance_ + accruedAmount_ + pendingAmount_;
        lastUpdate_ = lastUpdateTime[_account];
        holdingDuration_ = lastUpdate_ > 0 ? block.timestamp - lastUpdate_ : 0;
    }

    /**
     * @notice 预估未来收益
     * @param _account 用户地址
     * @param _futureTime 未来时间（秒）
     */
    function estimateFutureRewards(address _account, uint256 _futureTime) external view returns (uint256) {
        uint256 baseBalance_ = super.balanceOf(_account);
        if (baseBalance_ == 0 || !growthEnabled) {
            return 0;
        }

        uint256 weightMultiplier_ = _getWeightMultiplier(_futureTime);
        uint256 rewards_ =
            (baseBalance_ * annualYieldRate * _futureTime * weightMultiplier_) / (10000 * 365 days * 10000);

        return rewards_;
    }
}
