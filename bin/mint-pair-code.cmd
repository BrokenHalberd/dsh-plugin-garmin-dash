@echo off
REM mint-pair-code.cmd —— Windows 便捷包装：等价于 `node bin\mint-pair-code.mjs %*`
REM 用途：手机端/桌面快捷方式双击即可铸造配对码（宿主必须在运行）。
setlocal
node "%~dp0mint-pair-code.mjs" %*
exit /b %ERRORLEVEL%
