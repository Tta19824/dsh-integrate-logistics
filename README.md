# OrderPocket（冒烟测试）

一个极简 iOS 壳，用来验证这条链路是否走得通：

```
GitHub Actions（macOS）编译 → 未签名 ipa → SideStore 用你的 Apple ID 重签 → 装进 iPhone → 7 天后续签一次
```

**这个版本不抓任何数据**，它只做三件事：

1. 打开后显示三个按钮（拼多多 / 淘宝 / 京东），点了能在内嵌浏览器里加载对应网页
2. 点「查 Cookie」，验证 App 能不能读到 WebView 里的登录 cookie（真正的软件完全依赖这个能力）
3. 底部显示版本号，用来确认装的是哪一版

## 编译

仓库推到 GitHub 后自动触发，也可以在 Actions 页面手动点 `Run workflow`。

产物有两个入口：

- Actions → 最新一次构建 → Artifacts → `OrderPocket-ipa`
- Releases → `smoke` → `OrderPocket.ipa`（手机直接点这个链接就能下载）

## 安装到 iPhone（第一次）

1. **准备小号 Apple ID**：去 <https://appleid.apple.com> 登录后，在「登录与安全」里生成一个**App 专用密码**（形如 `abcd-efgh-ijkl-mnop`），记下来。
2. **装 SideStore 到手机**：按 SideStore 官网（<https://sidestore.io>）的步骤来。第一次需要一个电脑端工具（Windows 上用 AltServer 或 Sideloadly）把 SideStore 本体装进去，之后不再需要电脑。
3. **打开开发者模式**：设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机。
4. **导入 ipa**：把 `OrderPocket.ipa` 弄到手机上（AirDrop、iCloud Drive、或直接在手机 Safari 下载），用 SideStore 打开并安装。
5. **信任开发者**：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任你的 Apple ID。

## 续签（每 7 天）

手机上打开 SideStore → 点 Refresh / 刷新 → 等几秒。不需要电脑、不需要重新下载。

证书过期前 SideStore 会提前通知你。过期后 App 会闪退打不开，续签后恢复正常，**数据不会丢**。

## 注意

- 这个仓库只放代码。**任何 cookie、账号、登录信息都不会进仓库**，也不会出现在日志里。
- 免费签名有 7 天有效期，无法绕过。
- 免费签名不支持远程推送，也不稳定支持 App Group（所以不做桌面小组件）。
