@echo off
setlocal EnableExtensions EnableDelayedExpansion
title O-C GitHub Sync Tool

set "ROOT_DIR=%~dp0"
set "MAX_PUSH_ATTEMPTS=3"

if not exist "%ROOT_DIR%\.git" (
  echo [ERROR] Git repository not found:
  echo %ROOT_DIR%
  pause
  exit /b 1
)

cd /d "%ROOT_DIR%"

echo.
echo ===================================================
echo                 O-C Git Push Tool
echo ===================================================
echo.

echo [1/4] Checking git status...
echo ---------------------------------------------------
git status -s
echo ---------------------------------------------------
echo.

set "HAS_WORKTREE_CHANGES=0"
for /f %%i in ('git status --porcelain') do (
  set "HAS_WORKTREE_CHANGES=1"
  goto worktree_state_done
)
:worktree_state_done

set "CURRENT_BRANCH="
for /f "delims=" %%i in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set "CURRENT_BRANCH=%%i"
if not defined CURRENT_BRANCH (
  echo [ERROR] Unable to detect current branch.
  pause
  exit /b 1
)

set "HAS_UPSTREAM=0"
set "AHEAD_COUNT=0"
git rev-parse --abbrev-ref --symbolic-full-name @{u} >nul 2>nul
if not errorlevel 1 (
  set "HAS_UPSTREAM=1"
  for /f "delims=" %%i in ('git rev-list --count @{u}..HEAD 2^>nul') do set "AHEAD_COUNT=%%i"
  if not defined AHEAD_COUNT set "AHEAD_COUNT=0"
)

if "%HAS_WORKTREE_CHANGES%"=="0" if "%HAS_UPSTREAM%"=="1" if "%AHEAD_COUNT%"=="0" (
  echo [INFO] No local changes or pending commits. GitHub push skipped.
  echo.
  pause
  exit /b 0
)

set "msg=chore: sync local changes"

echo [2/5] Adding files...
git add .
if errorlevel 1 (
  echo [ERROR] git add failed.
  pause
  exit /b 1
)

echo.
echo [3/5] Committing...
git diff --cached --quiet
if errorlevel 1 (
  git -c core.quotepath=false commit -m "%msg%"
  if errorlevel 1 (
    echo [ERROR] git commit failed.
    pause
    exit /b 1
  )
) else (
  echo [INFO] Nothing new to commit, continuing to push existing commits...
)

echo.
echo [4/5] Checking GitHub connection...
set /a REMOTE_ATTEMPT=1

:remote_retry
git ls-remote origin HEAD >nul 2>nul
if not errorlevel 1 goto remote_ready

if %REMOTE_ATTEMPT% geq %MAX_PUSH_ATTEMPTS% (
  echo [ERROR] GitHub is temporarily unreachable after %MAX_PUSH_ATTEMPTS% checks. Please verify network access and try again.
  pause
  exit /b 1
)

echo [WARN] GitHub check failed. Retrying... attempt %REMOTE_ATTEMPT%/%MAX_PUSH_ATTEMPTS%
set /a REMOTE_ATTEMPT+=1
timeout /t 3 /nobreak >nul
goto remote_retry

:remote_ready

echo.
echo [5/5] Pushing to GitHub...
set /a PUSH_ATTEMPT=1

:push_retry
if "%HAS_UPSTREAM%"=="0" (
  git push -u origin %CURRENT_BRANCH%
) else (
  git push
)
if not errorlevel 1 goto push_success

if %PUSH_ATTEMPT% geq %MAX_PUSH_ATTEMPTS% (
  echo [ERROR] git push failed after %MAX_PUSH_ATTEMPTS% attempts. Please check network or GitHub credentials.
  pause
  exit /b 1
)

echo [WARN] Retrying git push... attempt %PUSH_ATTEMPT%/%MAX_PUSH_ATTEMPTS%
set /a PUSH_ATTEMPT+=1
timeout /t 3 /nobreak >nul
goto push_retry

:push_success

echo.
echo ===================================================
echo DONE! O-C successfully pushed to GitHub!
echo ===================================================
echo.
pause
