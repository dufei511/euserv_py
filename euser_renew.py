#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EUserv 自动续期脚本 - 多账号多线程版本
支持多账号配置、多线程并发处理、自动登录、验证码识别、检查到期状态、自动续期并发送 Telegram 通知
"""

import os
import hashlib
import html
import sys
import io
import re
import json
import time
import threading
import logging
from typing import Dict, List, Tuple, Optional
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

from PIL import Image
import ddddocr
import requests
from bs4 import BeautifulSoup
from imap_tools import MailBox, AND

from dotenv import load_dotenv
if os.path.exists('dev.env'):
    load_dotenv('dev.env')

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(threadName)s] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

# 全局 OCR 实例（线程安全）
ocr = ddddocr.DdddOcr(beta=True, show_ad=False)
ocr_lock = threading.Lock()

USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"


# ============== 工具函数 ==============
def resolve_imap_server(email: str) -> str:
    """
    根据邮箱域名自动推断 IMAP 服务器地址。
    支持常见邮箱，未识别时返回 None（需手动配置）。
    """
    IMAP_MAP = {
        'gmail.com':       'imap.gmail.com',
        'googlemail.com':  'imap.gmail.com',
        'outlook.com':     'imap-mail.outlook.com',
        'hotmail.com':     'imap-mail.outlook.com',
        'live.com':        'imap-mail.outlook.com',
        'msn.com':         'imap-mail.outlook.com',
        'yahoo.com':       'imap.mail.yahoo.com',
        'yahoo.co.uk':     'imap.mail.yahoo.co.uk',
        'yahoo.co.jp':     'imap.mail.yahoo.co.jp',
        'icloud.com':      'imap.mail.me.com',
        'me.com':          'imap.mail.me.com',
        'mac.com':         'imap.mail.me.com',
        'qq.com':          'imap.qq.com',
        '163.com':         'imap.163.com',
        '126.com':         'imap.126.com',
        'sina.com':        'imap.sina.com',
        'foxmail.com':     'imap.qq.com',
        'protonmail.com':  'imap.protonmail.com',  # 需开启 Bridge
        'proton.me':       'imap.protonmail.com',
        'zoho.com':        'imap.zoho.com',
        'aol.com':         'imap.aol.com',
        'gmx.com':         'imap.gmx.com',
        'gmx.de':          'imap.gmx.net',
        'web.de':          'imap.web.de',
        't-online.de':     'secureimap.t-online.de',
    }
    if not email or '@' not in email:
        return 'imap.gmail.com'
    domain = email.strip().lower().split('@')[-1]
    server = IMAP_MAP.get(domain)
    if server:
        return server
    # 未知域名：尝试通用规则 imap.<domain>
    logger.warning(f"⚠️ 未知邮箱域名 '{domain}'，使用推断地址 imap.{domain}，如不可用请手动配置")
    return f'imap.{domain}'


# ============== 配置数据类 ==============
class AccountConfig:
    """
    单个账号配置。
    email_pin: 用于接收 PIN 码的邮箱（可选）。
               未配置时自动使用 email 字段。
    imap_server: IMAP 服务器地址（可选）。
                 未配置时根据 email_pin（或 email）的域名自动推断。
    email_password: email_pin 邮箱的密码 / Gmail 应用专用密码。
    """
    def __init__(self, email, password, email_pin='', email_password='', imap_server=''):
        self.email = email
        self.password = password
        # email_pin 未配置则回退到 email
        self.email_pin = email_pin if email_pin else email
        self.email_password = email_password if email_password else password
        # imap_server 未配置则自动推断
        if imap_server:
            self.imap_server = imap_server
        else:
            self.imap_server = resolve_imap_server(self.email_pin)


class GlobalConfig:
    """全局配置"""
    def __init__(self, telegram_bot_token="", telegram_chat_id="", bark_url="", max_workers=3, max_login_retries=3):
        self.telegram_bot_token = telegram_bot_token
        self.telegram_chat_id = telegram_chat_id
        self.bark_url = bark_url  # 新增：Bark 推送 URL
        self.max_workers = max_workers
        self.max_login_retries = max_login_retries


# ============== 配置区 ==============
# 全局配置
GLOBAL_CONFIG = GlobalConfig(
    telegram_bot_token=os.getenv("TG_BOT_TOKEN"),   # TG 的 API Token
    telegram_chat_id=os.getenv("TG_CHAT_ID"),        # TG 的 User ID
    bark_url=os.getenv("BARK_URL"),                  # iOS Bark 推送，格式：https://api.day.app/your_key/
    max_workers=int(os.getenv("MAX_WORKERS", 3)),
    max_login_retries=int(os.getenv("MAX_LOGIN_RETRIES", 5)),
)


def load_accounts_from_env() -> List[AccountConfig]:
    """
    动态从环境变量加载账号，支持任意数量。
    第 1 个账号：EUSERV_EMAIL / EUSERV_PASSWORD / EMAIL_PIN / EMAIL_PASS
    第 N 个账号：EUSERV_EMAILN / EUSERV_PASSWORDN / EMAIL_PINN / EMAIL_PASSN（N >= 2）
    只要 EUSERV_EMAIL 存在即继续读取，遇到第一个空缺则停止。
    """
    accounts = []
    i = 1
    while True:
        suffix = "" if i == 1 else str(i)
        email = os.getenv(f"EUSERV_EMAIL{suffix}")
        if not email or not email.strip():
            break
        password = os.getenv(f"EUSERV_PASSWORD{suffix}")
        accounts.append(AccountConfig(
            email=email,
            password=password,
            email_pin=os.getenv(f"EMAIL_PIN{suffix}"),       # 可选，未配置则使用 EUSERV_EMAIL
            email_password=os.getenv(f"EMAIL_PASS{suffix}"),  # PIN 邮箱的密码（Gmail 应用专用密码等）
        ))
        i += 1
    return accounts


# 账号列表 - 动态从环境变量加载
# EMAIL_PIN：可选，用于接收登录/续期 PIN 码的邮箱，未配置则使用 EUSERV_EMAIL
# IMAP 服务器根据 EMAIL_PIN（或 EUSERV_EMAIL）域名自动推断，如需覆盖可在 AccountConfig 中手动指定
ACCOUNTS = load_accounts_from_env()

# ====================================


# 数字字符纠正映射表（用于操作数）—— 模块级常量，避免每次调用重建
_DIGIT_CORRECTIONS: Dict[str, str] = {
    'O': '0', 'o': '0',  # 字母O → 数字0
    'D': '0', 'Q': '0',  # D/Q可能是0
    'I': '1', 'i': '1', 'l': '1', '|': '1',  # I/l/竖线 → 数字1
    'Z': '2', 'z': '2',  # 字母Z → 数字2
    'S': '5', 's': '5',  # 字母S → 数字5
    'G': '6', 'b': '6',  # 字母G → 数字6
    'B': '8', 'g': '8',  # 字母B → 数字8
}

# 运算符映射表（用于中间位置）—— 模块级常量
_OPERATOR_CORRECTIONS: Dict[str, str] = {
    'T': '+', 't': '+', 'F': '+', 'f': '+', 'r': '+',  # T → 加号
    'I': '-', 'i': '-', '|': '-', '1': '-', 'l': '-',  # 竖线类 → 减号
    'x': '×', 'X': '×',  # x/X → 乘号
    '*': '×', '×': '×',  # 统一乘号
    '÷': '/', ':': '/',  # 统一除号
    '+': '+', '-': '-', '/': '/',  # 保留原有运算符
}


def recognize_and_calculate(captcha_image_url: str, session: requests.Session) -> Optional[str]:
    """识别并计算验证码（线程安全）"""
    
    def aggressive_digit_convert(text: str) -> str:
        """激进的数字转换：尽可能把所有字符转为数字"""
        result = []
        for char in text:
            if char.isdigit():
                result.append(char)
            elif char in _DIGIT_CORRECTIONS:
                result.append(_DIGIT_CORRECTIONS[char])
            elif char.upper() in _DIGIT_CORRECTIONS:
                result.append(_DIGIT_CORRECTIONS[char.upper()])
            else:
                result.append(char)
        return ''.join(result)
    
    logger.info("正在处理验证码...")
    try:
        logger.debug("尝试自动识别验证码...")
        response = session.get(captcha_image_url)
        img = Image.open(io.BytesIO(response.content)).convert('RGB')

        # 颜色过滤 + 二值化 + 去边框（优先使用 numpy 向量化一步处理）
        border = 10
        threshold = 200
        try:
            import numpy as np
            arr = np.array(img, dtype=np.uint8)
            # 保留橙色文字 (R>200, 100<G<220, B<80)，其余噪点置白
            fg_mask = (arr[:, :, 0] > 200) & (arr[:, :, 1] > 100) & (arr[:, :, 1] < 220) & (arr[:, :, 2] < 80)
            # 橙色文字灰度值 < 200，二值化后前景为 0（黑），背景为 255（白）
            gray = np.where(fg_mask, 0, 255).astype(np.uint8)
            # 去除四周 10px 边框
            gray[:border, :] = 255
            gray[-border:, :] = 255
            gray[:, :border] = 255
            gray[:, -border:] = 255
            img = Image.fromarray(gray, mode='L').point(lambda x: 0 if x < threshold else 255, '1')
        except ImportError:
            # numpy 不可用时回退到逐像素处理
            pixels = img.load()
            width, height = img.size
            for x in range(width):
                for y in range(height):
                    r, g, b = pixels[x, y]
                    if not (r > 200 and 100 < g < 220 and b < 80):
                        pixels[x, y] = (255, 255, 255)
            img = img.convert('L').point(lambda x: 0 if x < threshold else 255, '1')
            pixels = img.load()
            for x in range(width):
                for y in range(height):
                    if x < border or x >= width - border or y < border or y >= height - border:
                        pixels[x, y] = 255
        
        output = io.BytesIO()
        img.save(output, format='PNG')
        processed_bytes = output.getvalue()
        
        # OCR 识别（加锁保证线程安全）
        with ocr_lock:
            text = ocr.classification(processed_bytes, png_fix=True).strip()
        
        logger.debug(f"OCR 原始识别: {text}")

        # 预处理：去除空格
        raw_text = text.strip().replace(' ', '')
        text_len = len(raw_text)
        
        logger.info(f"验证码长度: {text_len}, 内容: {raw_text}")
        
        # ===== 情况1：长度 >= 6，按纯字母数字验证码处理 =====
        if text_len >= 6:
            logger.info(f"检测到 >= 6 位验证码，按纯字母数字处理: {raw_text}")
            return raw_text.upper()  # 统一大写返回
        
        # ===== 情况2：长度 < 6，按运算验证码处理 =====
        logger.info(f"检测到 < 6 位验证码，按运算验证码处理: {raw_text}")
        
        # 尝试多种解析策略
        # 策略1：标准3位格式 (数字 运算符 数字)
        if text_len == 3:
            left_char, mid_char, right_char = raw_text[0], raw_text[1], raw_text[2]
            
            # 左右转数字，中间转运算符
            left_corrected = _DIGIT_CORRECTIONS.get(left_char, left_char)
            right_corrected = _DIGIT_CORRECTIONS.get(right_char, right_char)
            op_char = _OPERATOR_CORRECTIONS.get(mid_char, mid_char)
            
            logger.debug(f"3位纠正: '{left_char}'→'{left_corrected}' '{mid_char}'→'{op_char}' '{right_char}'→'{right_corrected}'")
            
            if left_corrected.isdigit() and right_corrected.isdigit():
                result = calculate_operation(int(left_corrected), op_char, int(right_corrected), raw_text)
                if result is not None:
                    return result
        
        # 策略2：正则匹配运算表达式（支持多位数）
        # 先进行字符纠正
        corrected_text = raw_text
        for old, new in _DIGIT_CORRECTIONS.items():
            corrected_text = corrected_text.replace(old, new)
        
        # 匹配模式：数字 + 运算符 + 数字
        pattern = r'^(\d+)([+\-×*/÷:xX])(\d+)$'
        match = re.match(pattern, corrected_text)
        
        if match:
            left_str, op, right_str = match.groups()
            op = _OPERATOR_CORRECTIONS.get(op, op)  # 运算符纠正
            
            left = int(left_str)
            right = int(right_str)
            
            logger.debug(f"正则匹配成功: {left} {op} {right}")
            result = calculate_operation(left, op, right, raw_text)
            if result is not None:
                return result
        
        # 策略3：激进纠正 - 强制把所有非数字转为数字，再尝试解析
        logger.warning("常规解析失败，尝试激进纠正...")
        aggressive_text = aggressive_digit_convert(raw_text)
        logger.debug(f"激进纠正结果: {raw_text} → {aggressive_text}")
        
        # 如果纠正后全是数字，尝试按位置推断运算符
        if aggressive_text.isdigit() and len(aggressive_text) >= 3:
            # 假设：倒数第二位可能是被误识别的运算符
            # 例如："253" 可能是 "2+3"（中间的5被误识别）
            if len(aggressive_text) == 3:
                left = int(aggressive_text[0])
                right = int(aggressive_text[2])
                # 尝试常见运算符
                for op in ['+', '-', '×', '/']:
                    result = calculate_operation(left, op, right, raw_text, silent=True)
                    if result is not None and 0 <= int(result) <= 20:  # 结果在合理范围
                        logger.info(f"激进推断成功: {left} {op} {right} = {result}")
                        return result
        
        # 策略4：如果还有字母，再次尝试强制转换
        if not aggressive_text.isdigit():
            logger.warning(f"包含无法转换的字符: {aggressive_text}")
            # 最后尝试：移除所有非数字非运算符字符
            cleaned = re.sub(r'[^0-9+\-×*/÷]', '', corrected_text)
            match = re.match(r'^(\d+)([+\-×*/÷])(\d+)$', cleaned)
            if match:
                left_str, op, right_str = match.groups()
                result = calculate_operation(int(left_str), op, int(right_str), raw_text)
                if result is not None:
                    logger.info(f"清理后解析成功: {cleaned}")
                    return result
        
        # 所有策略都失败，返回原始文本
        logger.warning(f"所有解析策略均失败，返回原始文本: {raw_text}")
        return raw_text
        
    except Exception as e:
        logger.error(f"验证码识别发生错误: {e}", exc_info=True)
        return None


def calculate_operation(left: int, op: str, right: int, raw_text: str, silent: bool = False) -> Optional[str]:
    """
    执行运算并返回结果
    silent: 是否静默模式（不输出日志，用于批量尝试）
    """
    try:
        if op == '+':
            result = left + right
            op_name = '加'
        elif op == '-':
            result = left - right
            op_name = '减'
        elif op in {'×', '*', 'x', 'X'}:
            result = left * right
            op_name = '乘'
        elif op in {'/', '÷', ':'}:
            if right == 0:
                if not silent:
                    logger.warning("除数为0，无法计算")
                return None
            if left % right != 0:
                if not silent:
                    logger.warning(f"除法非整除: {left} ÷ {right} = {left / right}")
                return None
            result = left // right
            op_name = '除'
        else:
            if not silent:
                logger.warning(f"未知运算符: {op}")
            return None
        
        if not silent:
            logger.info(f"验证码计算: {left} {op_name} {right} = {result}")
        return str(result)
    except Exception as e:
        if not silent:
            logger.error(f"计算错误: {e}")
        return None







def get_euserv_pin(email: str, email_password: str, imap_server: str,
                   max_retries: int = 6, retry_interval: int = 5,
                   max_age_seconds: int = 90) -> Optional[str]:
    """从邮箱获取 EUserv PIN 码（带轮询重试 + 时效性校验）

    因 PIN 邮件可能有延迟，会按 retry_interval 秒间隔最多重试 max_retries 次。
    只接受 max_age_seconds 秒内发送的 PIN，避免拿到旧 PIN 导致续期失败。

    Args:
        email: 邮箱地址
        email_password: 邮箱密码
        imap_server: IMAP 服务器地址
        max_retries: 最大重试次数（默认 6 次）
        retry_interval: 每轮间隔秒数（默认 5 秒）
        max_age_seconds: 最大 PIN 邮件时效（默认 90 秒，超过则跳过等待新邮件）
    """
    # 统一使用 UTC 时间作为时效起点（以进入函数的时刻向前回溯 max_age_seconds）
    cutoff_utc = datetime.now(timezone.utc) - timedelta(seconds=max_age_seconds)
    for attempt in range(1, max_retries + 1):
        try:
            if attempt > 1:
                logger.info(f"PIN 邮件尚未到达，{retry_interval} 秒后第 {attempt}/{max_retries} 次重试...")
                time.sleep(retry_interval)

            logger.info(f"正在从邮箱 {email} 获取 PIN 码（第 {attempt}/{max_retries} 次）...")
            with MailBox(imap_server).login(email, email_password) as mailbox:
                for msg in mailbox.fetch(AND(from_='no-reply@euserv.com', body='PIN'), limit=1, reverse=True):
                    logger.debug(f"找到邮件: {msg.subject}, 收件时间: {msg.date_str}")

                    # ★ 时效性校验：统一转换为 UTC 时区进行比较，跳过旧邮件
                    msg_date = msg.date
                    if msg_date:
                        msg_date_utc = (
                            msg_date.astimezone(timezone.utc)
                            if msg_date.tzinfo is not None
                            else msg_date.replace(tzinfo=timezone.utc)
                        )
                        if msg_date_utc < cutoff_utc:
                            logger.info(f"PIN 邮件时间 {msg_date_utc} 早于阈值 {cutoff_utc}，可能为旧 PIN，等待新邮件...")
                            continue

                    match = re.search(r'PIN:\s*\n?(\d{6})', msg.text)
                    if match:
                        pin = match.group(1)
                        logger.info(f"✅ 提取到 PIN 码: {pin}")
                        return pin
                    else:
                        match_fallback = re.search(r'(\d{6})', msg.text)
                        if match_fallback:
                            pin = match_fallback.group(1)
                            logger.warning(f"⚠️ 备选匹配 PIN 码: {pin}")
                            return pin

        except Exception as e:
            logger.warning(f"第 {attempt} 次获取 PIN 时出错: {e}")
            if attempt < max_retries:
                time.sleep(retry_interval)
                continue
            logger.error(f"获取 PIN 码失败（已重试 {max_retries} 次）")
            return None

    logger.warning("❌ 未找到符合条件的 EUserv 邮件")
    return None


class EUserv:
    """EUserv 操作类"""

    # Cookie 文件保存目录
    COOKIE_DIR = "cookies"

    def __init__(self, config: AccountConfig):
        self.config = config
        self.session = requests.Session()
        self.sess_id = None
        self.c_id = None
        # 每个账号对应一个独立的 cookie 文件
        os.makedirs(self.COOKIE_DIR, exist_ok=True)
        safe_name = hashlib.md5(config.email.encode()).hexdigest()
        self.cookie_file = os.path.join(self.COOKIE_DIR, f"{safe_name}.json")
        # 初始化时尝试加载已保存的 Cookie（让服务器识别为受信任设备，跳过 PIN）
        self._load_cookies()

    def _save_cookies(self):
        """将当前 session 的 Cookie 持久化到文件（保留完整属性）"""
        try:
            cookies = [
                {
                    'name':    c.name,
                    'value':   c.value,
                    'domain':  c.domain or 'support.euserv.com',
                    'path':    c.path or '/',
                    'expires': c.expires,
                    'secure':  c.secure,
                }
                for c in self.session.cookies
            ]
            with open(self.cookie_file, 'w', encoding='utf-8') as f:
                json.dump(cookies, f)
            logger.info(f"✅ 信任设备 Cookie 已保存: {self.cookie_file}")
        except Exception as e:
            logger.warning(f"⚠️ 保存 Cookie 失败: {e}")

    def _load_cookies(self):
        """从文件加载 Cookie 到 session，兼容旧版 name→value 格式"""
        if not os.path.exists(self.cookie_file):
            return
        try:
            with open(self.cookie_file, 'r', encoding='utf-8') as f:
                cookies = json.load(f)
            # 兼容旧格式 {"name": "value", ...}
            if isinstance(cookies, dict):
                for name, value in cookies.items():
                    self.session.cookies.set(name, value, domain='support.euserv.com')
            else:
                # 新格式：完整属性列表
                for c in cookies:
                    self.session.cookies.set(
                        c['name'], c['value'],
                        domain=c.get('domain', 'support.euserv.com'),
                        path=c.get('path', '/'),
                    )
            logger.info("🍪 已加载信任设备 Cookie，登录时将跳过 PIN 验证")
        except Exception as e:
            logger.warning(f"⚠️ 加载 Cookie 失败: {e}")

    def login(self) -> bool:
        """登录 EUserv（支持验证码和 PIN，Cookie 持久化跳过 PIN）"""
        logger.info(f"正在登录账号: {self.config.email}")

        headers = {
            'user-agent': USER_AGENT,
            'origin': 'https://www.euserv.com'
        }
        url = "https://support.euserv.com/index.iphp"
        captcha_url = "https://support.euserv.com/securimage_show.php"

        try:
            # 获取 sess_id（session 里已携带 Cookie，服务器可识别为受信任设备）
            sess = self.session.get(url, headers=headers)
            sess_id_match = re.search(r'sess_id["\']?\s*[:=]\s*["\']?([a-zA-Z0-9]{30,100})["\']?', sess.text)
            if not sess_id_match:
                sess_id_match = re.search(r'sess_id=([a-zA-Z0-9]{30,100})', sess.text)

            if not sess_id_match:
                logger.error("❌ 无法获取 sess_id")
                return False

            sess_id = sess_id_match.group(1)
            logger.debug(f"获取到 sess_id: {sess_id[:20]}...")

            # 访问 logo
            logo_png_url = "https://support.euserv.com/pic/logo_small.png"
            self.session.get(logo_png_url, headers=headers)

            # 提交登录表单
            login_data = {
                'email': self.config.email,
                'password': self.config.password,
                'form_selected_language': 'en',
                'Submit': 'Login',
                'subaction': 'login',
                'sess_id': sess_id
            }

            logger.debug("提交登录表单...")
            response = self.session.post(url, headers=headers, data=login_data)
            response.raise_for_status()

            # 解析返回页面
            soup = BeautifulSoup(response.text, "lxml")

            # 检查登录错误
            if 'Please check email address/customer ID and password' in response.text:
                logger.error("❌ 用户名或密码错误")
                return False
            if 'kc2_login_iplock_cdown' in response.text:
                logger.error("❌ 密码错误次数过多，账号被锁定，请5分钟后重试")
                return False

            # 处理验证码
            if 'captcha' in response.text.lower():
                logger.info("⚠️ 需要验证码，正在识别...")

                max_captcha_retries = 10
                for captcha_attempt in range(max_captcha_retries):
                    if captcha_attempt > 0:
                        logger.warning(f"验证码识别失败，第 {captcha_attempt + 1}/{max_captcha_retries} 次重试...")
                        time.sleep(3)

                    captcha_code = recognize_and_calculate(captcha_url, self.session)

                    if not captcha_code:
                        logger.error("❌ 验证码识别失败")
                        return False

                    captcha_data = {
                        'subaction': 'login',
                        'sess_id': sess_id,
                        'captcha_code': captcha_code
                    }

                    response = self.session.post(url, headers=headers, data=captcha_data)
                    response.raise_for_status()

                    if 'captcha' in response.text.lower():
                        logger.warning(f"❌ 验证码错误（第 {captcha_attempt + 1} 次）")
                        if captcha_attempt < max_captcha_retries - 1:
                            continue
                        else:
                            logger.error("❌ 验证码错误次数过多，重新进入登录流程")
                            return False
                    else:
                        soup = BeautifulSoup(response.text, "lxml")
                        logger.info("✅ 验证码验证成功")
                        break

            # 处理 PIN 验证
            # 若之前 Cookie 有效，服务器不会返回 PIN 页面，直接跳过这段
            if 'PIN that you receive via email' in response.text:
                c_id_input = soup.find("input", {"name": "c_id"})
                if not c_id_input or not c_id_input.get("value"):
                    logger.error("❌ 无法从 PIN 验证页面提取 c_id")
                    return False
                self.c_id = c_id_input["value"]
                logger.info("⚠️ 需要 PIN 验证（首次登录或 Cookie 已失效）")
                time.sleep(8)  # ★ 等邮件送达

                pin = get_euserv_pin(
                    self.config.email_pin,
                    self.config.email_password,
                    self.config.imap_server,
                    max_age_seconds=60  # ★ 只接受最近 60 秒内的 PIN
                )

                if not pin:
                    logger.error("❌ 获取 PIN 码失败")
                    return False

                login_confirm_data = {
                    'pin': pin,
                    'save_for_auto_login': 'on',
                    'sess_id': sess_id,
                    'Submit': 'Confirm',
                    'subaction': 'login',
                    'c_id': self.c_id,
                }
                response = self.session.post(url, headers=headers, data=login_confirm_data)
                response.raise_for_status()

                # PIN 验证成功后，服务器种下信任设备 Cookie，立即持久化
                self._save_cookies()
                logger.info("🍪 PIN 验证完成，信任设备 Cookie 已保存，下次登录将跳过 PIN")

            # 检查登录成功
            success_checks = [
                'Hello' in response.text,
                'Confirm or change your customer data here' in response.text,
                'logout' in response.text.lower() and 'customer' in response.text.lower()
            ]

            if any(success_checks):
                logger.info(f"✅ 账号 {self.config.email} 登录成功")
                self.sess_id = sess_id
                return True
            else:
                logger.error(f"❌ 账号 {self.config.email} 登录失败")
                return False

        except Exception as e:
            logger.error(f"❌ 登录过程出现异常: {e}", exc_info=True)
            return False
    


    def update_info(self):
            # 支持通过环境变量 UPDATE_INFO_DAYS 自定义触发日（逗号分隔），默认 2,22
            _days_str = os.getenv("UPDATE_INFO_DAYS", "2,22")
            try:
                _update_days = {int(d.strip()) for d in _days_str.split(',') if d.strip().isdigit()}
            except Exception:
                _update_days = {2, 22}
            if not _update_days:
                _update_days = {2, 22}

            current_day = datetime.now().day
            if current_day not in _update_days:
                return True  # 非更新日不是失败

            logger.info("更新用户信息...")
            try:
                # 1. 进入用户信息界面
                url = f"https://support.euserv.com/index.iphp?sess_id={self.sess_id}&action=show_customerdata"
                headers = {
                    'user-agent': USER_AGENT,
                    'host': 'support.euserv.com',
                    'referer': f'https://support.euserv.com/index.iphp?sess_id={self.sess_id}&subaction=show_kwk_main'
                }

                logger.info("进入用户界面...")
                response = self.session.get(url=url, headers=headers)
                response.raise_for_status()

                soup = BeautifulSoup(response.text, 'lxml')

                # ── 工具函数 ────────────────────────────────────────────────
                def _val(name):
                    """读取 text/hidden input 的 value，找不到返回空串。"""
                    tag = soup.find('input', {'name': name})
                    return tag.get('value', '').strip() if tag else ''

                def _sel(selector):
                    """读取 select 中选中 option 的 value，找不到返回空串。"""
                    opt = soup.select_one(f'{selector} option[selected]')
                    return opt.get('value', '') if opt else ''

                def _checkbox(name):
                    """
                    checkbox：已勾选返回 value（通常为 '1'），未勾选返回 None。
                    None 表示该字段不应出现在 POST body 里（与浏览器行为一致）。
                    """
                    tag = soup.find('input', {'name': name, 'type': 'checkbox'})
                    if tag and tag.get('checked') is not None:
                        return tag.get('value', '1')
                    return None

                def _vals(name):
                    """读取同名 input 列表（c_birthday[]、c_phone[]、c_fax[]）。"""
                    return [t.get('value', '').strip() for t in soup.find_all('input', {'name': name})]

                # ── 提取 c_id ────────────────────────────────────────────────
                if not self.c_id:
                    self.c_id = _val('c_id')

                # ── 修复🔴：新增 c_fname / c_lname ────────────────────────────
                c_fname = _val('c_fname')
                c_lname = _val('c_lname')

                # ── 修复🟡：动态读取 c_ustid[]（text + select 各一个）─────────
                c_ustid_text = [t.get('value', '') for t in soup.find_all('input', {'name': 'c_ustid[]'})]
                c_ustid_sel = []
                for s in soup.find_all('select', {'name': 'c_ustid[]'}):
                    opt = s.find('option', selected=True)
                    c_ustid_sel.append(opt.get('value', '') if opt else '')
                c_ustid_value = c_ustid_text + c_ustid_sel  # 保持与表单顺序一致

                # ── 修复🟢：c_org 动态读取，不再硬编码为空 ────────────────────
                c_org = _val('c_org')

                # ── 普通字段 ─────────────────────────────────────────────────
                c_att                  = _sel('#c_att')
                c_street               = _val('c_street')
                c_streetno             = _val('c_streetno')
                c_postal               = _val('c_postal')
                c_city                 = _val('c_city')
                c_country              = _sel('#c_country')
                c_phone_country_prefix = _val('c_phone_country_prefix')
                c_phone_password       = _val('c_phone_password')
                c_fax_country_prefix   = _val('c_fax_country_prefix')
                c_website              = _val('c_website')
                c_firstcontact         = _sel('#c_firstcontact')
                c_forumnick            = _val('c_forumnick')
                c_hrno                 = _val('c_hrno')
                c_hrcourt              = _val('c_hrcourt')
                c_taxid                = _val('c_taxid')
                c_identifier           = _val('c_identifier')
                c_birthplace           = _val('c_birthplace')
                c_country_of_birth     = _sel('#c_country_of_birth')

                # ── 修复🟢：列表字段用列表推导，避免无效的 Tag truthy 判断 ────
                c_birthday_value = _vals('c_birthday[]')
                c_phone_value    = _vals('c_phone[]')
                c_fax_value      = _vals('c_fax[]')

                # ── 修复🔴：checkbox 按浏览器语义处理 ────────────────────────
                c_tac_date          = _checkbox('c_tac_date')
                c_emailabo_contract = _checkbox('c_emailabo_contract')
                c_emailabo_products = _checkbox('c_emailabo_products')

                # ── 构造 POST body ────────────────────────────────────────────
                upInfo_data = {
                    'sess_id':               self.sess_id,
                    'subaction':             'kc2_customer_data_update',
                    'c_id':                  self.c_id,
                    'c_fname':               c_fname,           # 🔴 新增
                    'c_lname':               c_lname,           # 🔴 新增
                    'c_org':                 c_org,             # 🟢 动态
                    'c_ustid[]':             c_ustid_value,     # 🟡 动态
                    'c_att':                 c_att,
                    'c_street':              c_street,
                    'c_streetno':            c_streetno,
                    'c_postal':              c_postal,
                    'c_city':                c_city,
                    'c_country':             c_country,
                    'c_birthday[]':          c_birthday_value,
                    'c_phone_country_prefix': c_phone_country_prefix,
                    'c_phone[]':             c_phone_value,
                    'c_phone_password':      c_phone_password,
                    'c_fax_country_prefix':  c_fax_country_prefix,
                    'c_fax[]':               c_fax_value,
                    'c_website':             c_website,
                    'c_firstcontact':        c_firstcontact,
                    'c_forumnick':           c_forumnick,
                    'c_hrno':                c_hrno,
                    'c_hrcourt':             c_hrcourt,
                    'c_taxid':               c_taxid,
                    'c_identifier':          c_identifier,
                    'c_birthplace':          c_birthplace,
                    'c_country_of_birth':    c_country_of_birth,
                }

                # 🔴 checkbox 未勾选时不传（与浏览器行为一致）
                if c_tac_date is not None:
                    upInfo_data['c_tac_date'] = c_tac_date
                if c_emailabo_contract is not None:
                    upInfo_data['c_emailabo_contract'] = c_emailabo_contract
                if c_emailabo_products is not None:
                    upInfo_data['c_emailabo_products'] = c_emailabo_products

                # ── 提交 ─────────────────────────────────────────────────────
                logger.info("提交保存用户信息...")
                response = self.session.post(
                    url='https://support.euserv.com/index.iphp',
                    headers=headers,
                    data=upInfo_data
                )
                response.raise_for_status()

                if 'customer data has been changed' in response.text:
                    logger.info("✅ 保存用户信息成功")
                    return True
                else:
                    logger.warning(f"⚠️ 保存用户信息失败，response={response.text[:500]}")
                    return False

            except Exception as e:
                logger.error(f"❌ 更新用户信息异常: {e}", exc_info=True)
                return False


    def get_servers(self) -> Dict[str, Tuple[bool, str]]:
        """获取服务器列表"""
        logger.info(f"正在获取账号 {self.config.email} 的服务器列表...")
        
        if not self.sess_id:
            logger.error("❌ 未登录")
            return {}
        
        url = f"https://support.euserv.com/index.iphp?sess_id={self.sess_id}"
        headers = {'user-agent': USER_AGENT, 'origin': 'https://www.euserv.com'}
        
        try:
            detail_response = self.session.get(url=url, headers=headers)
            detail_response.raise_for_status()

            soup = BeautifulSoup(detail_response.text, 'lxml')
            servers = {}

            # 修复1: 动态匹配所有 Tab，不硬编码 ID
            all_tabs = soup.select('[id^="kc2_order_customer_orders_tab_content_"]')
            
            for tab in all_tabs:
                for tr in tab.select('.kc2_order_table.kc2_content_table tr'):
                    server_id_cells = tr.select('.td-z1-sp1-kc')
                    if len(server_id_cells) != 1:
                        continue
                    
                    # 修复: 优先查找嵌套的 action_container，不依赖列数索引
                    action_container = tr.select_one('.td-z1-sp2-kc .kc2_order_action_container')
                    if action_container:
                        action_text = action_container.get_text(strip=True)
                    else:
                        # 兜底：取最后一个 td-z1-sp2-kc 单元格内容
                        action_cells = tr.select('.td-z1-sp2-kc')
                        if not action_cells:
                            continue
                        action_text = action_cells[-1].get_text(strip=True)
                    logger.debug(f"续期信息: {action_text}")

                    can_renew = True
                    can_renew_date = ""
                    
                    if "Contract extension possible from" in action_text:
                        date_match = re.search(r'\b(\d{4}-\d{2}-\d{2})\b', action_text)
                        if date_match:
                            can_renew_date = date_match.group(1)
                            can_renew = datetime.today().date() >= datetime.strptime(can_renew_date, "%Y-%m-%d").date()
                        else:
                            # 有提示但没解析出日期，保守处理为不可续期
                            can_renew = False

                    server_id_text = server_id_cells[0].get_text(strip=True)
                    servers[server_id_text] = (can_renew, can_renew_date)
            
            logger.info(f"✅ 账号 {self.config.email} 找到 {len(servers)} 台服务器")
            return servers
            
        except Exception as e:
            logger.error(f"❌ 获取服务器列表失败: {e}", exc_info=True)
            return {}
    
    def renew_server(self, order_id: str) -> bool:
        """续期服务器"""
        logger.info(f"正在续期服务器 {order_id}...")
        
        url = "https://support.euserv.com/index.iphp"
        headers = {
            'user-agent': USER_AGENT,
            'Host': 'support.euserv.com',
            'origin': 'https://support.euserv.com',
            'Referer': 'https://support.euserv.com/index.iphp'
        }
        
        try:
            # 步骤1: 选择订单
            logger.debug("步骤1: 选择订单...")
            data = {
                'Submit': 'Extend contract',
                'sess_id': self.sess_id,
                'ord_no': order_id,
                'subaction': 'choose_order',
                'show_contract_extension': '1',
                'choose_order_subaction': 'show_contract_details'
            }
            resp1 = self.session.post(url, headers=headers, data=data)
            resp1.raise_for_status()
            
            # 步骤2: 触发发送 PIN
            logger.debug("步骤2: 触发发送 PIN...")
            data = {
                'sess_id': self.sess_id,
                'subaction': 'show_kc2_security_password_dialog',
                'prefix': 'kc2_customer_contract_details_extend_contract_',
                'type': '1'
            }
            resp2 = self.session.post(url, headers=headers, data=data)
            resp2.raise_for_status()
            # 检查PIN发送响应
            if resp2.status_code != 200:
                logger.error("❌ PIN发送请求失败")
                return False

            # ★ 等待 PIN 邮件送达邮箱（IMAP 延迟通常 5-15 秒）
            logger.info("⏳ 等待 PIN 邮件送达...（15 秒）")
            time.sleep(15)

            # 步骤3: 获取 PIN（内部有轮询重试）
            logger.debug("步骤3: 获取 PIN 码...")
            pin = get_euserv_pin(
                self.config.email_pin,
                self.config.email_password,
                self.config.imap_server,
                max_age_seconds=60  # ★ 只接受最近 60 秒内的 PIN
            )
            
            if not pin:
                logger.error("❌ 获取续期 PIN 码失败")
                return False
        
            # 步骤4: 验证 PIN 获取 token
            logger.debug("步骤4: 验证 PIN 获取 token...")
            data = {
                'sess_id': self.sess_id,
                'auth': pin,
                'subaction': 'kc2_security_password_get_token',
                'prefix': 'kc2_customer_contract_details_extend_contract_',
                'type': '1',
                'ident': 'kc2_customer_contract_details_extend_contract_' + order_id
            }
            
            resp3 = self.session.post(url, headers=headers, data=data)
            resp3.raise_for_status()

            result = json.loads(resp3.text)
            if result.get('rs') != 'success':
                logger.error(f"❌ 获取 token 失败: {result.get('rs', 'unknown')}")
                if 'error' in result:
                    logger.error(f"错误信息: {result['error']}")
                return False
            
            token = result['token']['value']
            logger.debug(f"✅ 获取到 token: {token[:20]}...")
            time.sleep(2)

            # 步骤4.5: 弹出小窗
            logger.debug("步骤4.5: 确认续期图...")
            data = {
                'sess_id': self.sess_id,
                'subaction': 'kc2_customer_contract_details_get_extend_contract_confirmation_dialog',
                'token': token
            }
            resp4 = self.session.post(url, headers=headers, data=data)
            resp4.raise_for_status()


            # 步骤5: 提交续期请求
            logger.debug("步骤5: 提交续期请求...")
            data = {
                'sess_id': self.sess_id,
                'ord_id': order_id,
                'subaction': 'kc2_customer_contract_details_extend_contract_term',
                'token': token
            }
      
            resp5 = self.session.post(url, headers=headers, data=data)
            resp5.raise_for_status()
            # with open('debug_resp5.html', 'w', encoding='utf-8') as f:
            #     f.write(resp5.text)
            
            # 步骤6: 验证续期结果（重新拉取服务器列表，对比可续期日期是否变化）
            logger.debug("步骤6: 点击续期13秒后验证续期结果...")
            time.sleep(13)
            servers_after = self.get_servers()
            if order_id in servers_after:
                can_renew_after, new_date = servers_after[order_id]
                # 续期成功特征：服务器不再处于"可续期"状态
                if not can_renew_after:
                    logger.info(f"✅ 服务器 {order_id} 续期验证通过（新可续期日期: {new_date}）")
                    return True
                else:
                    logger.warning(f"⚠️ 服务器 {order_id} 续期后状态未变化，可能续期未生效（可续期日期: {new_date}）")
                    return False
            else:
                # 无法重新获取该服务器信息，保守认为成功（接口本身未报错）
                logger.warning(f"⚠️ 服务器 {order_id} 续期后无法重新获取状态，接口未报错，视为成功")
                return True
            
        except json.JSONDecodeError as e:
            logger.error(f"❌ JSON 解析失败: {e}", exc_info=True)
            return False
        except Exception as e:
            logger.error(f"❌ 服务器 {order_id} 续期失败: {e}", exc_info=True)
            return False




def send_bark(title: str, content: str, config: GlobalConfig):
    """
    发送 Bark 推送通知
    
    Args:
        title: 推送标题
        content: 推送内容
        config: 全局配置对象
    """
    if not config.bark_url:
        logger.warning("⚠️ 未配置 Bark URL，跳过 Bark 通知")
        return
    
    try:
        post_url = config.bark_url.rstrip('/')
        data = {
            "title": title,
            "body": content,
            "sound": "telegraph",  # 推送音效
            "group": "EUserv",     # 分组
            "icon": "https://www.euserv.com/favicon.ico"  # 自定义图标
        }
        
        # 发送请求
        response = requests.post(post_url, json=data, timeout=20)
        
        if response.status_code == 200:
            result = response.json()
            if result.get('code') == 200:
                logger.info("✅ Bark 推送发送成功")
            else:
                logger.error(f"❌ Bark 推送失败: {result.get('message', '未知错误')}")
        else:
            logger.error(f"❌ Bark 推送失败: HTTP {response.status_code}")
            
    except Exception as e:
        logger.error(f"❌ Bark 推送异常: {e}", exc_info=True)



def send_telegram(message: str, config: GlobalConfig):
    """发送 Telegram 通知"""
    if not config.telegram_bot_token or not config.telegram_chat_id:
        logger.warning("⚠️ 未配置 Telegram，跳过通知")
        return
    
    url = f"https://api.telegram.org/bot{config.telegram_bot_token}/sendMessage"
    data = {
        "chat_id": config.telegram_chat_id,
        "text": message,
        "parse_mode": "HTML"
    }
    
    try:
        response = requests.post(url, json=data, timeout=10)
        if response.status_code == 200:
            logger.info("✅ Telegram 通知发送成功")
        else:
            logger.error(f"❌ Telegram 通知失败: {response.status_code}")
    except Exception as e:
        logger.error(f"❌ Telegram 异常: {e}", exc_info=True)


def send_notification(title: str, message: str, config: GlobalConfig):
    """
    统一发送通知（支持 Telegram 和 Bark）
    
    Args:
        title: 通知标题（主要用于 Bark）
        message: 通知内容
        config: 全局配置对象
    """
    # 发送 Telegram 通知
    send_telegram(message, config)
    
    # 发送 Bark 通知（将 HTML 格式转为纯文本并还原转义字符）
    plain_message = html.unescape(re.sub(r'<[^>]+>', '', message))  # 移除 HTML 标签
    send_bark(title, plain_message, config)


def process_account(account_config: AccountConfig, global_config: GlobalConfig) -> Dict:
    """处理单个账号的续期任务"""
    result = {
        'email': account_config.email,
        'success': False,
        'servers': {},
        'renew_results': [],
        'error': None,
        'error_type': None,   # 'login' | 'get_servers' | 'exception'
    }
    
    try:
        euserv = EUserv(account_config)
        
        # 登录（最多重试）
        login_success = False
        for attempt in range(global_config.max_login_retries):
            if attempt > 0:
                logger.info(f"账号 {account_config.email} 第 {attempt + 1} 次登录尝试...")
                time.sleep(5)
            
            if euserv.login():
                login_success = True
                break
        
        if not login_success:
            result['error'] = "登录失败"
            result['error_type'] = 'login'
            return result
        
        # 更新用户信息（不影响续期主流程）
        if not euserv.update_info():
            logger.warning(f"⚠️ 账号 {account_config.email} 更新用户信息失败，续期流程继续")

        # 获取服务器列表
        servers = euserv.get_servers()
        result['servers'] = servers
        
        if not servers:
            result['error'] = "未找到任何服务器"
            result['error_type'] = 'get_servers'
            result['success'] = True  # 登录成功，只是没有服务器
            return result
        
        # 检查并续期
        for order_id, (can_renew, can_renew_date) in servers.items():
            logger.info(f"检查服务器: {order_id}")
            if can_renew:
                logger.info(f"⏰ 服务器 {order_id} 可以续期")
                if euserv.renew_server(order_id):
                    result['renew_results'].append({
                        'order_id': order_id,
                        'success': True,
                        'message': f"✅ 服务器 {order_id} 续期成功"
                    })
                else:
                    result['renew_results'].append({
                        'order_id': order_id,
                        'success': False,
                        'message': f"❌ 服务器 {order_id} 续期失败"
                    })
            else:
                logger.info(f"✓ 服务器 {order_id} 暂不需要续期（可续期日期: {can_renew_date}）")
        
        result['success'] = True
        
    except Exception as e:
        logger.error(f"处理账号 {account_config.email} 时发生异常: {e}", exc_info=True)
        result['error'] = str(e)
        result['error_type'] = 'exception'
    
    return result


def main():
    """主函数"""
    logger.info("=" * 60)
    logger.info("EUserv 多账号自动续期脚本（多线程版本）")
    logger.info(f"执行时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    logger.info(f"配置账号数: {len(ACCOUNTS)}")
    logger.info(f"最大并发线程: {GLOBAL_CONFIG.max_workers}")
    logger.info("=" * 60)
    
    if not ACCOUNTS:
        logger.error("❌ 未配置任何账号")
        sys.exit(1)
    
    # 使用线程池处理多个账号
    all_results = []
    with ThreadPoolExecutor(max_workers=GLOBAL_CONFIG.max_workers) as executor:
        # 提交所有任务
        future_to_account = {
            executor.submit(process_account, account, GLOBAL_CONFIG): account 
            for account in ACCOUNTS
            if account.email and str(account.email).strip() and account.password and str(account.password).strip() and account.email_password and str(account.email_password).strip()
        }
        
        # 等待任务完成
        for future in as_completed(future_to_account):
            account = future_to_account[future]
            try:
                result = future.result()
                all_results.append(result)
            except Exception as e:
                logger.error(f"处理账号 {account.email} 时发生未预期的异常: {e}", exc_info=True)
                all_results.append({
                    'email': account.email,
                    'success': False,
                    'error': f"未预期的异常: {str(e)}"
                })
    
    # 生成汇总报告 & 按需通知
    logger.info("\n" + "=" * 60)
    logger.info("处理结果汇总")
    logger.info("=" * 60)
    
    # 判断是否需要发通知
    notify_parts = []   # 需要通知的内容片段
    time_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    for result in all_results:
        email = result['email']
        safe_email = html.escape(str(email))
        logger.info(f"\n账号: {email}")

        if not result['success']:
            error_type = result.get('error_type', 'exception')
            error_msg = result.get('error', '未知错误')
            safe_error = html.escape(str(error_msg))
            logger.error(f"  ❌ 处理失败: {error_msg}")

            # ① 登录失败 → 通知
            if error_type == 'login':
                notify_parts.append(
                    f"<b>📧 {safe_email}</b>\n  ❌ 登录处理失败: {safe_error}"
                )
            # ② 其他异常 → 通知
            elif error_type == 'exception':
                notify_parts.append(
                    f"<b>📧 {safe_email}</b>\n  ❌ 处理异常: {safe_error}"
                )
            continue

        servers = result.get('servers', {})
        logger.info(f"  服务器数量: {len(servers)}")

        # ③ 获取服务器信息失败 → 通知
        if result.get('error_type') == 'get_servers':
            error_msg = result.get('error', '')
            logger.warning(f"  ⚠️ {error_msg}")
            notify_parts.append(
                f"<b>📧 {safe_email}</b>\n  ⚠️ 获取服务器信息失败: {html.escape(str(error_msg))}"
            )
            continue

        renew_results = result.get('renew_results', [])
        if renew_results:
            logger.info(f"  续期操作: {len(renew_results)} 个")
            renew_lines = []
            for rr in renew_results:
                logger.info(f"    {rr['message']}")
                renew_lines.append(f"  {html.escape(str(rr['message']))}")
            # ④ 有续期操作（不管成功失败）→ 通知
            notify_parts.append(
                f"<b>📧 {safe_email}</b>\n" + "\n".join(renew_lines)
            )
        else:
            # ⑤ 无需续期 → 仅记录日志，不发通知
            logger.info("  ✓ 所有服务器均无需续期")
            for order_id, (can_renew, can_renew_date) in servers.items():
                if can_renew_date:
                    logger.info(f"    订单 {order_id}: 可续期日期 {can_renew_date}")

    # 发送通知（同步调用，确保发送完成再退出）
    if notify_parts:
        header = f"<b>🔄 EUserv 续期通知</b>\n时间: {time_str}\n"
        message = header + "\n\n".join(notify_parts)
        send_notification("EUserv 续期通知", message, GLOBAL_CONFIG)
    else:
        logger.info("✅ 本次无续期操作，无需发送通知")
    
    logger.info("\n" + "=" * 60)
    logger.info("执行完成")
    logger.info("=" * 60)
    if all_results and not any(r.get('success') for r in all_results):
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()