# by Gemini 2.5 Flash

import os
import sys
import select
import time

def wait_for_pid_with_pidfd(pid_to_wait):
    """
    指定されたPIDのプロセスが終了するのをpidfdを使って待機する
    """
    if not (sys.version_info >= (3, 9)):
        print("Error: Python 3.9 or higher is required for os.pidfd_open.", file=sys.stderr)
        return 1

    # カーネルバージョンが5.3以上かチェック (簡易的な確認)
    kernel_version = os.uname().release
    try:
        major_version = int(kernel_version.split('.')[0])
        minor_version = int(kernel_version.split('.')[1])
        if major_version < 5 or (major_version == 5 and minor_version < 3):
            print(f"Error: Linux kernel 5.3 or higher is required for pidfd_open. Current: {kernel_version}", file=sys.stderr)
            return 1
    except (ValueError, IndexError):
        print(f"Warning: Could not parse kernel version '{kernel_version}'. Assuming compatible.", file=sys.stderr)

    try:
        # 指定されたPIDのpidfdを開く
        pidfd = os.pidfd_open(pid_to_wait, 0)
        if pidfd == -1:
            print(f"Error: Could not open pidfd for PID {pid_to_wait}.", file=sys.stderr)
            # エラーコードを返すことで、PIDが存在しないなどの場合にbashで検知できるようにする
            return 1 
        
        print(f"Waiting for PID {pid_to_wait} using pidfd (FD: {pidfd})...")

        # pidfdが読み込み可能になるのを待つ (プロセス終了を意味する)
        # select.select はタイムアウトなし (None) で無限に待機
        readable, _, _ = select.select([pidfd], [], [], None)

        if pidfd in readable:
            print(f"PID {pid_to_wait} has terminated.")
            return 0 # 成功
        else:
            print(f"Unexpected error: pidfd {pidfd} not in readable set.", file=sys.stderr)
            return 1
    except ProcessLookupError:
        print(f"Error: PID {pid_to_wait} does not exist or has already terminated.", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"An OS error occurred: {e}", file=sys.stderr)
        return 1
    finally:
        if 'pidfd' in locals() and pidfd != -1:
            os.close(pidfd) # pidfdを閉じる

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python wait_for_pidfd.py <PID>", file=sys.stderr)
        sys.exit(1)

    try:
        target_pid = int(sys.argv[1])
    except ValueError:
        print("Error: PID must be an integer.", file=sys.stderr)
        sys.exit(1)

    sys.exit(wait_for_pid_with_pidfd(target_pid))
