#!/usr/bin/env python3
"""
NZXT H1 V2 Dynamic Fan Control
Manages fan speeds independently based on their cooling duties:
- Fan1 (92mm): GPU exhaust fan - controlled by GPU temperature
- Fan2 (140mm): AIO radiator fan - controlled by CPU temperature
"""

import subprocess
import time
import sys
import re
from collections import deque
from typing import Optional, Tuple, Dict
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger(__name__)

class FanController:
    def __init__(self):
        # Temperature curves for different fans - optimized for quiet operation
        # Fan1 (GPU exhaust) - stay quiet until high temps
        self.gpu_fan_curve = [
            (50, 25),   # Below 50°C: 25% (very quiet)
            (60, 30),   # 60°C: 30%
            (70, 35),   # 70°C: 35%
            (75, 40),   # 75°C: 40%
            (80, 50),   # 80°C: 50% (max quiet threshold)
            (85, 65),   # 85°C: 65%
            (90, 80),   # 90°C: 80%
            (95, 90),   # 95°C: 90%
            (float('inf'), 100),  # Above 95°C: 100%
        ]
        
        # Fan2 (CPU/AIO) - very conservative, liquid cooling has thermal mass
        self.cpu_fan_curve = [
            (40, 20),   # Below 40°C: 20% (silent)
            (50, 25),   # 50°C: 25%
            (60, 30),   # 60°C: 30%
            (70, 35),   # 70°C: 35%
            (75, 40),   # 75°C: 40%
            (80, 50),   # 80°C: 50% (max quiet threshold)
            (85, 70),   # 85°C: 70%
            (90, 85),   # 90°C: 85%
            (float('inf'), 100),  # Above 90°C: 100%
        ]
        
        # Control parameters
        self.history_size = 10  # 20 seconds of history (2s intervals)
        self.cpu_temp_history = deque(maxlen=self.history_size)
        self.gpu_temp_history = deque(maxlen=self.history_size)
        
        # Current fan speeds (default to quiet)
        self.current_gpu_fan_speed = 25
        self.current_cpu_fan_speed = 20
        
        # Timing control
        self.last_gpu_change_time = 0
        self.last_cpu_change_time = 0
        self.min_change_interval = 15  # seconds
        self.min_change_interval_small = 25  # seconds for small changes
        
        # Hysteresis
        self.hysteresis = 2  # degrees C
        self.hysteresis_high_temp = 1  # reduced hysteresis for high temps
        
        # Status tracking
        self.loop_count = 0
        self.status_interval = 15  # Log status every 30 seconds (15 * 2s)
        
    def run_command(self, cmd: list) -> Optional[str]:
        """Run a command and return output, or None on error"""
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                return result.stdout.strip()
            else:
                logger.error(f"Command failed: {' '.join(cmd)}")
                return None
        except subprocess.TimeoutExpired:
            logger.error(f"Command timed out: {' '.join(cmd)}")
            return None
        except Exception as e:
            logger.error(f"Error running command: {e}")
            return None
    
    def initialize_device(self) -> bool:
        """Initialize the NZXT device"""
        logger.info("Initializing NZXT H1 V2...")
        output = self.run_command(["liquidctl", "initialize"])
        if output:
            logger.info("Device initialized successfully")
            return True
        return False
    
    def get_cpu_temperature(self) -> Optional[int]:
        """Get the highest CPU core temperature"""
        output = self.run_command(["sensors", "-u", "coretemp-isa-0000"])
        if not output:
            return None
        
        temps = []
        for line in output.split('\n'):
            if '_input:' in line:
                try:
                    temp = float(line.split(':')[1].strip())
                    temps.append(int(temp))
                except (ValueError, IndexError):
                    continue
        
        return max(temps) if temps else None
    
    def get_gpu_temperature(self) -> Optional[int]:
        """Get GPU temperature (AMD GPU using amdgpu driver)"""
        # Try AMD GPU first
        output = self.run_command(["sensors", "-u", "amdgpu-pci-0300"])
        if not output:
            # Try alternative sensor names
            output = self.run_command(["sensors", "-u"])
            if not output:
                return None
        
        # Look for GPU temperature - check for edge: or junction: labels followed by temp input
        lines = output.split('\n')
        for i, line in enumerate(lines):
            if 'edge:' in line.lower():
                # Next line should have the temperature
                if i + 1 < len(lines):
                    next_line = lines[i + 1]
                    if 'temp' in next_line and '_input:' in next_line:
                        try:
                            temp = float(next_line.split(':')[1].strip())
                            return int(temp)
                        except (ValueError, IndexError):
                            continue
            elif 'junction:' in line.lower():
                # Next line should have the temperature
                if i + 1 < len(lines):
                    next_line = lines[i + 1]
                    if 'temp' in next_line and '_input:' in next_line:
                        try:
                            temp = float(next_line.split(':')[1].strip())
                            return int(temp)
                        except (ValueError, IndexError):
                            continue
        
        return None
    
    def get_current_fan_speeds(self) -> Dict[str, int]:
        """Get current fan speeds from liquidctl"""
        output = self.run_command(["liquidctl", "status"])
        speeds = {"fan1": 25, "fan2": 20}  # Defaults (quiet)
        
        if not output:
            return speeds
        
        for line in output.split('\n'):
            if 'Fan 1 duty' in line:
                try:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part == 'duty':
                            speeds["fan1"] = int(parts[i+1])
                except (ValueError, IndexError):
                    continue
            elif 'Fan 2 duty' in line:
                try:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part == 'duty':
                            speeds["fan2"] = int(parts[i+1])
                except (ValueError, IndexError):
                    continue
        
        return speeds
    
    def set_fan_speed(self, fan: str, speed: int) -> bool:
        """Set fan speed for a specific fan"""
        output = self.run_command(["liquidctl", "set", fan, "speed", str(speed)])
        return output is not None
    
    def get_target_speed(self, temp: float, curve: list) -> int:
        """Get target fan speed for given temperature from curve"""
        for threshold, speed in curve:
            if temp <= threshold:
                return speed
        return 100
    
    def apply_hysteresis(self, target_speed: int, current_speed: int, avg_temp: float, curve: list, high_temp_threshold: int = 70) -> int:
        """Apply hysteresis to prevent oscillation"""
        if target_speed == current_speed:
            return target_speed
        
        # Use reduced hysteresis for high temperatures
        hysteresis = self.hysteresis_high_temp if avg_temp > high_temp_threshold else self.hysteresis
        
        if target_speed > current_speed:
            # For increasing speed, require temperature to be above threshold + hysteresis
            for i, (threshold, speed) in enumerate(curve):
                if speed == target_speed:
                    if i > 0:
                        prev_threshold = curve[i-1][0]
                        if avg_temp < prev_threshold + hysteresis:
                            return current_speed
                    break
        else:
            # For decreasing speed, require temperature to be below threshold - hysteresis
            for i, (threshold, speed) in enumerate(curve):
                if speed == current_speed:
                    if avg_temp > threshold - hysteresis - 2:
                        return current_speed
                    break
        
        return target_speed
    
    def should_change_speed(self, target_speed: int, current_speed: int, last_change_time: float, min_history: int = 5) -> bool:
        """Check if enough time has passed and conditions are met for speed change"""
        if target_speed == current_speed:
            return False
        
        current_time = time.time()
        time_since_change = current_time - last_change_time
        
        # Determine minimum interval based on change size
        speed_diff = abs(target_speed - current_speed)
        required_interval = self.min_change_interval_small if speed_diff <= 15 else self.min_change_interval
        
        # Check time constraint
        if time_since_change < required_interval:
            return False
        
        return True
    
    def run(self):
        """Main control loop"""
        if not self.initialize_device():
            logger.error("Failed to initialize device")
            return
        
        # Get initial state
        initial_cpu_temp = self.get_cpu_temperature() or 40
        initial_gpu_temp = self.get_gpu_temperature() or 40
        logger.info(f"Initial temperatures - CPU: {initial_cpu_temp}°C, GPU: {initial_gpu_temp}°C")
        
        # Get current fan speeds
        current_speeds = self.get_current_fan_speeds()
        self.current_gpu_fan_speed = current_speeds["fan1"]
        self.current_cpu_fan_speed = current_speeds["fan2"]
        logger.info(f"Current fan speeds - GPU Fan (fan1): {self.current_gpu_fan_speed}%, CPU Fan (fan2): {self.current_cpu_fan_speed}%")
        
        # Set initial fan speeds based on temperatures
        initial_gpu_target = self.get_target_speed(initial_gpu_temp, self.gpu_fan_curve)
        initial_cpu_target = self.get_target_speed(initial_cpu_temp, self.cpu_fan_curve)
        
        if initial_gpu_target != self.current_gpu_fan_speed:
            logger.info(f"Setting GPU fan to {initial_gpu_target}% based on temp {initial_gpu_temp}°C")
            if self.set_fan_speed("fan1", initial_gpu_target):
                self.current_gpu_fan_speed = initial_gpu_target
        
        if initial_cpu_target != self.current_cpu_fan_speed:
            logger.info(f"Setting CPU fan to {initial_cpu_target}% based on temp {initial_cpu_temp}°C")
            if self.set_fan_speed("fan2", initial_cpu_target):
                self.current_cpu_fan_speed = initial_cpu_target
        
        # Main control loop
        while True:
            try:
                self.loop_count += 1
                
                # Get current temperatures
                cpu_temp = self.get_cpu_temperature()
                gpu_temp = self.get_gpu_temperature()
                
                if cpu_temp is None:
                    logger.warning("Failed to read CPU temperature, using last known")
                    cpu_temp = self.cpu_temp_history[-1] if self.cpu_temp_history else 40
                
                if gpu_temp is None:
                    logger.warning("Failed to read GPU temperature, using last known")
                    gpu_temp = self.gpu_temp_history[-1] if self.gpu_temp_history else 40
                
                # Update temperature histories
                self.cpu_temp_history.append(cpu_temp)
                self.gpu_temp_history.append(gpu_temp)
                
                # Calculate average temperatures
                avg_cpu_temp = sum(self.cpu_temp_history) / len(self.cpu_temp_history) if self.cpu_temp_history else cpu_temp
                avg_gpu_temp = sum(self.gpu_temp_history) / len(self.gpu_temp_history) if self.gpu_temp_history else gpu_temp
                
                # GPU Fan (Fan1) Control
                gpu_base_target = self.get_target_speed(avg_gpu_temp, self.gpu_fan_curve)
                gpu_target = self.apply_hysteresis(gpu_base_target, self.current_gpu_fan_speed, avg_gpu_temp, self.gpu_fan_curve, 70)
                
                if self.should_change_speed(gpu_target, self.current_gpu_fan_speed, self.last_gpu_change_time):
                    if self.set_fan_speed("fan1", gpu_target):
                        logger.info(f"GPU: {gpu_temp}°C (avg: {avg_gpu_temp:.1f}°C), Fan1: {self.current_gpu_fan_speed}% -> {gpu_target}%")
                        self.current_gpu_fan_speed = gpu_target
                        self.last_gpu_change_time = time.time()
                    else:
                        logger.error(f"Failed to set GPU fan to {gpu_target}%")
                
                # CPU Fan (Fan2) Control
                cpu_base_target = self.get_target_speed(avg_cpu_temp, self.cpu_fan_curve)
                cpu_target = self.apply_hysteresis(cpu_base_target, self.current_cpu_fan_speed, avg_cpu_temp, self.cpu_fan_curve, 75)
                
                if self.should_change_speed(cpu_target, self.current_cpu_fan_speed, self.last_cpu_change_time):
                    if self.set_fan_speed("fan2", cpu_target):
                        logger.info(f"CPU: {cpu_temp}°C (avg: {avg_cpu_temp:.1f}°C), Fan2: {self.current_cpu_fan_speed}% -> {cpu_target}%")
                        self.current_cpu_fan_speed = cpu_target
                        self.last_cpu_change_time = time.time()
                    else:
                        logger.error(f"Failed to set CPU fan to {cpu_target}%")
                
                # Periodic status logging
                if self.loop_count % self.status_interval == 0:
                    logger.info(f"Status: CPU {cpu_temp}°C (avg {avg_cpu_temp:.1f}°C) Fan2={self.current_cpu_fan_speed}%, "
                              f"GPU {gpu_temp}°C (avg {avg_gpu_temp:.1f}°C) Fan1={self.current_gpu_fan_speed}%")
                
                time.sleep(2)
                
            except KeyboardInterrupt:
                logger.info("Shutting down...")
                break
            except Exception as e:
                logger.error(f"Unexpected error in main loop: {e}")
                time.sleep(5)  # Wait before retrying

if __name__ == "__main__":
    controller = FanController()
    controller.run()