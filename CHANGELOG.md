# 更新日志 (Changelog)

所有针对 Argo 项目的重要变更、审查修复与安全加固均记录于此。

---

## [2026-11-04] - 深度代码审查与核心缺陷加固

### 修复与安全加固 (Commit `9e89d1d`)
- **宿主机隔离保护**：在 `nodejs/index.js` 与 `python/app.py` 中引入 `isContainerEnvironment()` 校验，仅在检测到真实容器环境（Docker / Containerd / LXC）时才执行 `/proc/uptime` bind mount，彻底防止 VPS 宿主机开机时间被意外篡改。
- **异步 Socket 泄漏修复**：在 Node.js `dispatchUplinkData` 内部增加了 `xhttpSessions.has(session.id)` 门禁，消除客户端中途断线时的孤儿连接泄漏。
- **未捕获异常防崩**：在 WebSocket 连接提早断开并销毁 Socket 时，预先挂载空错误监听，彻底杜绝 Node.js `unhandled 'error'` 异常导致的进程崩溃。
- **全链路流控背压**：
  - Node.js WebSocket 上行增加了 `remoteSocket.write()` 返回值检查，并联动底层 `ws._socket.pause()` 与 `drain` 恢复；
  - Node.js 单次 POST XHTTP 增加了 `req.pause()` 与 `drain` 联动；
  - Python 会话中的 `downlink_queue` 与 `uplink_queue` 设置了 `maxsize=128` 有界门禁，防止内存无限膨胀。
- **原生下载器重构**：`downloadBinary` 支持最大 5 跳防死循环重定向、动态 `http/https` 协议自动适配、15 秒全局超时熔断以及临时残损文件自动清理。
- **空闲保活与延迟优化**：出站连接全量开启 `SO_KEEPALIVE`（15s 心跳）与 `TCP_NODELAY`。
- **Dockerfile 容器权限优化**：穿透与监控核心部署目录迁移至 `/opt/argo-core` 并赋 `755` 权限，完美兼容非 root 容器运行环境。
- **文档维护**：
  - 生成 [`CODE_AUDIT_REPORT.md`](./CODE_AUDIT_REPORT.md)；
  - 更新二轮复查验收结果，完成所有遗留与回归缺陷的闭环修复。

### 修复与完善（二轮复查后续）
- **Python 单次 POST 全双工生命周期修复**：在客户端读完上行数据后，调用 `r_writer.write_eof()` 发送半关闭，任务以 `await t2`（下行响应结束）为生命周期终点，彻底解决客户端上传结束后响应被过早强制终止的问题。
- **Python 异步建连门禁补齐**：在 `dispatch_xhttp_uplink` 中异步建连完成后增加 `if sess['closed'] or sess['id'] not in xhttp_sessions:` 校验，若会话已作废立即安全释放 Socket，杜绝孤儿连接泄漏。
