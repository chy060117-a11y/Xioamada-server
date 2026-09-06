@echo off
chcp 65001 >nul
title 小马达能量营 - 账号服务
cd /d %~dp0bin
echo ============================================
echo   小马达能量营 - 账号服务启动中...
echo ============================================
echo.
echo 本机局域网 IP（手机要填的地址）：
ipconfig | findstr /C:"IPv4"
echo.
echo 服务地址：http://本机IP:8080
echo 手机 App 在「我的-我的账号-账号服务器」中填入上面的地址。
echo 首次运行如弹出 Windows 防火墙提示，请点「允许访问」。
echo 按 Ctrl+C 可停止服务，关闭本窗口即停止。
echo.
dart server.dart 8080
pause
