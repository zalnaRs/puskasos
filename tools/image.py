import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
import subprocess
import threading
import os
import json
import time


class App:
    def __init__(self, root):
        self.root = root
        self.root.title("Bootc Image Builder & Flasher")
        self.root.geometry("850x650")

        self.setup_ui()
        self.refresh_disks()

    def setup_ui(self):
        frame = ttk.Frame(self.root, padding=10)
        frame.pack(fill=tk.BOTH, expand=True)

        # Image Builder Section
        builder_frame = ttk.LabelFrame(frame, text="1. Build Image", padding=10)
        builder_frame.pack(fill=tk.X, pady=(0, 10))

        ttk.Label(builder_frame, text="Container Source:").pack(
            side=tk.LEFT, padx=(0, 10)
        )
        self.container_ref_var = tk.StringVar(
            value="ghcr.io/zalnars/puskasos:br-stable-10"
        )
        ttk.Entry(builder_frame, textvariable=self.container_ref_var, width=55).pack(
            side=tk.LEFT, padx=(0, 10), fill=tk.X, expand=True
        )

        self.build_btn = ttk.Button(
            builder_frame, text="Build .raw Image", command=self.start_build
        )
        self.build_btn.pack(side=tk.RIGHT)

        self.pull_btn = ttk.Button(
            builder_frame, text="Pull Container", command=self.start_pull
        )
        self.pull_btn.pack(side=tk.RIGHT, padx=(0, 10))

        # Flasher Section
        flasher_frame = ttk.LabelFrame(frame, text="2. Flash to Disk", padding=10)
        flasher_frame.pack(fill=tk.X, pady=(0, 10))

        ttk.Label(flasher_frame, text="Target Disk:").pack(side=tk.LEFT, padx=(0, 10))
        self.disk_var = tk.StringVar()
        self.disk_cb = ttk.Combobox(
            flasher_frame, textvariable=self.disk_var, state="readonly", width=45
        )
        self.disk_cb.pack(side=tk.LEFT, padx=(0, 10), fill=tk.X, expand=True)

        ttk.Button(
            flasher_frame, text="Refresh Disks", command=self.refresh_disks
        ).pack(side=tk.LEFT, padx=(0, 10))

        self.flash_btn = ttk.Button(
            flasher_frame, text="Write & Resize Partition", command=self.start_flash
        )
        self.flash_btn.pack(side=tk.RIGHT)

        # Status/Log Section
        log_frame = ttk.LabelFrame(frame, text="Activity Logs", padding=10)
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = scrolledtext.ScrolledText(
            log_frame,
            state="disabled",
            bg="#1e1e1e",
            fg="#cccccc",
            font=("Consolas", 10),
        )
        self.log_text.pack(fill=tk.BOTH, expand=True)

        self.append_log(
            "Ready.\nNote: Operations require pkexec privileges. If prompted in terminal, please enter your password.\n"
        )

    def run_command(self, cmd, desc="Command"):
        self.append_log(f"\n--- Starting: {desc} ---\n> {' '.join(cmd)}\n")
        try:
            # We use bufsize=1 and universal_newlines=True to read lines interactively
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            for line in iter(process.stdout.readline, ""):
                if line:
                    self.append_log(line)
            process.stdout.close()
            return_code = process.wait()
            if return_code != 0:
                self.append_log(f"--- FAILED: {desc} (Exit Status {return_code}) ---\n")
                return False
            else:
                self.append_log(f"--- SUCCESS: {desc} ---\n")
                return True
        except Exception as e:
            self.append_log(f"Exception during {desc}: {e}\n")
            return False

    def refresh_disks(self):
        try:
            res = subprocess.check_output(["lsblk", "-J", "-do", "NAME,SIZE,MODEL"])
            disks = json.loads(res)["blockdevices"]
            disk_list = []
            for d in disks:
                name = d.get("name", "")
                if name.startswith("loop"):
                    continue

                model = d.get("model", "Unknown")
                size = d.get("size", "Unknown")
                disk_list.append(f"/dev/{name} - [{size}] - {model}")

            self.disk_cb["values"] = disk_list
            if disk_list:
                self.disk_cb.current(0)
        except Exception as e:
            self.append_log(f"Failed to refresh disks: {e}\n")

    def start_build(self):
        self.build_btn.state(["disabled"])
        self.pull_btn.state(["disabled"])
        self.flash_btn.state(["disabled"])
        t = threading.Thread(target=self.build_thread, daemon=True)
        t.start()

    def start_pull(self):
        self.build_btn.state(["disabled"])
        self.pull_btn.state(["disabled"])
        self.flash_btn.state(["disabled"])
        t = threading.Thread(target=self.pull_thread, daemon=True)
        t.start()

    def pull_thread(self):
        cmd = [
            "podman",
            "pull",
            self.container_ref_var.get().strip()
        ]
        self.run_command(cmd, "Pulling container image")
        self.root.after(0, self.enable_buttons)

    def build_thread(self):
        cmd = [
            "pkexec",
            "podman",
            "run",
            "--rm",
            "--privileged",
            "--pull=newer",
            "--security-opt",
            "label=type:unconfined_t",
        ]

        # Determine paths natively since we run in current directory
        cfg_path = os.path.abspath("config.toml")
        if os.path.exists(cfg_path):
            cmd.extend(["-v", f"{cfg_path}:/config.toml:ro"])
        else:
            self.append_log(
                f"Warning: Configuration file not found locally: {cfg_path}. Attempting to build without injecting it.\n"
            )

        out_path = os.path.abspath("output")
        os.makedirs(out_path, exist_ok=True)

        cmd.extend(
            [
                "-v",
                f"{out_path}:/output",
                "-v",
                "/var/lib/containers/storage:/var/lib/containers/storage",
                "quay.io/centos-bootc/bootc-image-builder:latest",
                "--type",
                "raw",
                "--use-librepo=False",
                "--rootfs",
                "btrfs",
                "-v",
                "--progress",
                "verbose",
                self.container_ref_var.get().strip(),
            ]
        )

        self.run_command(cmd, "Building bootc raw image")
        self.root.after(0, self.enable_buttons)

    def start_flash(self):
        disk_selection = self.disk_var.get()
        if not disk_selection:
            messagebox.showwarning("Warning", "Please select a target disk.")
            return

        target_disk = disk_selection.split(" - ")[0].strip()

        if not messagebox.askyesno(
            "Confirm Flashing",
            f"Are you sure you want to completely overwrite {target_disk}?\n\nTHIS WILL DESTROY ALL DATA ON IT!",
        ):
            return

        self.build_btn.state(["disabled"])
        self.pull_btn.state(["disabled"])
        self.flash_btn.state(["disabled"])
        t = threading.Thread(target=self.flash_thread, args=(target_disk,), daemon=True)
        t.start()

    def flash_thread(self, target_disk):
        target_image = ""
        # Search for .raw file in output dir recursively
        out_path = os.path.abspath("output")
        if os.path.exists(out_path):
            for root, dirs, files in os.walk(out_path):
                for file in files:
                    if file.endswith(".raw"):
                        target_image = os.path.join(root, file)
                        break
                if target_image:
                    break

        if not target_image or not os.path.exists(target_image):
            self.append_log(f"ERROR: Could not find built .raw image in {out_path}\n")
            self.root.after(0, self.enable_buttons)
            return

        self.append_log(f"Found image to flash: {target_image}\n")

        # 1. Flash the image
        # Note: status=progress spam output too much in pipe, we use plain status.
        dd_cmd = [
            "pkexec",
            "dd",
            f"if={target_image}",
            f"of={target_disk}",
            "bs=16M",
            "oflag=sync",
        ]
        if not self.run_command(dd_cmd, "Writing Image to Disk (dd)"):
            self.root.after(0, self.enable_buttons)
            return

        # 2. Fix GPT
        self.run_command(
            ["pkexec", "sgdisk", "-e", target_disk], "Fixing GPT Backup Table"
        )

        # 3. Reload partitions cache
        self.run_command(
            ["pkexec", "partprobe", target_disk], "Reloading Partition Tables"
        )
        time.sleep(2)  # Give kernel time to see new partition boundaries natively

        # 4. Find last partition dynamically and resize
        try:
            lsblk_cmd = ["lsblk", "-J", target_disk]
            output = subprocess.check_output(lsblk_cmd).decode("utf-8")
            data = json.loads(output)
            children = data.get("blockdevices", [])[0].get("children", [])
            if not children:
                self.append_log("No partitions found to resize on the target disk.\n")
            else:
                last_part = children[-1]
                last_part_name = last_part.get("name")
                target_disk_name = target_disk.replace("/dev/", "")

                # Extract partition number (e.g. sda3 -> 3, nvme0n1p2 -> 2)
                part_num = last_part_name.replace(target_disk_name, "")
                if part_num.startswith("p"):
                    part_num = part_num[1:]
                part_num = part_num.strip()
                self.append_log(
                    f"Detected last partition: /dev/{last_part_name} (Partition Number: {part_num})\n"
                )

                parted_cmd = [
                    "pkexec",
                    "parted",
                    "-s",
                    "-a",
                    "opt",
                    target_disk,
                    "resizepart",
                    part_num,
                    "100%",
                ]
                self.run_command(
                    parted_cmd, f"Resizing Partition {part_num} to fill disk"
                )

                # Signal change again
                self.run_command(
                    ["pkexec", "partprobe", target_disk],
                    "Updating Kernel with Resized Boundaries",
                )

        except Exception as e:
            self.append_log(f"Exception during partition resize calculation: {e}\n")

        self.root.after(0, self.enable_buttons)
        self.append_log("\n--- COMPLETE ---\n")

    def enable_buttons(self):
        self.build_btn.state(["!disabled"])
        self.pull_btn.state(["!disabled"])
        self.flash_btn.state(["!disabled"])

    def append_log(self, text):
        def _append():
            self.log_text.config(state="normal")
            self.log_text.insert(tk.END, text)
            self.log_text.see(tk.END)
            self.log_text.config(state="disabled")

        if threading.current_thread() == threading.main_thread():
            _append()
        else:
            self.root.after(0, _append)


if __name__ == "__main__":
    root = tk.Tk()
    app = App(root)
    root.mainloop()
