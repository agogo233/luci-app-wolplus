/**
 * wol.c - 轻量级 Wake-on-LAN 唤醒工具
 * 
 * 编译: 
 *   Linux 本地编译   : make linux
 *   MinGW 交叉编译    : make windows
 * 
 * 用法:
 *   ./wol <MAC地址> [IP地址] [端口]
 * 
 * 参数:
 *   MAC地址  目标设备MAC (格式 AA:BB:CC:DD:EE:FF 或 AA-BB-CC-DD-EE-FF)
 *   IP地址   广播地址 (默认 255.255.255.255)
 *   端口     目标端口 (默认 9)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>

#ifdef _WIN32
    /* Windows 平台 */
    #include <winsock2.h>
    #include <windows.h>
    #include <ws2tcpip.h>
    
    /* 关闭 socket 的兼容函数 */
    #define CLOSE_SOCKET(s)  closesocket(s)
#else
    /* Linux/POSIX 平台 */
    #include <unistd.h>
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    
    #define CLOSE_SOCKET(s)  close(s)
#endif

#define WOL_PORT_DEFAULT    9
#define WOL_PKT_SIZE        102
#define MAC_STR_LEN         17
#define MAC_OCTETS          6
#define MAC_REPEAT          16

/* 输出错误信息并退出 */
static void die(const char *msg)
{
    fprintf(stderr, "错误: %s\n", msg);
    exit(EXIT_FAILURE);
}

/* 打印用法 */
static void usage(const char *prog)
{
    fprintf(stderr, "用法: %s <MAC地址> [IP地址] [端口]\n", prog);
    fprintf(stderr, "  MAC地址: 目标设备的MAC地址 (如 AA:BB:CC:DD:EE:FF 或 AA-BB-CC-DD-EE-FF)\n");
    fprintf(stderr, "  IP地址:  广播地址 (默认 255.255.255.255)\n");
    fprintf(stderr, "  端口:    目标端口 (默认 9)\n");
}

/**
 * 解析 MAC 地址字符串
 * 支持 AA:BB:CC:DD:EE:FF 和 AA-BB-CC-DD-EE-FF 格式
 * 
 * @param mac_str  输入的MAC地址字符串
 * @param mac_out  输出6字节MAC地址缓冲区
 * @return 成功返回0，失败返回-1
 */
static int parse_mac(const char *mac_str, uint8_t *mac_out)
{
    size_t len = strlen(mac_str);

    /* 基本长度校验 */
    if (len != MAC_STR_LEN) {
        return -1;
    }

    /* 检查分隔符一致性 */
    char sep = mac_str[2];
    if (sep != ':' && sep != '-') {
        return -1;
    }

    /* 校验格式: 每两个hex字符 + 分隔符 */
    for (int i = 0; i < MAC_OCTETS; i++) {
        int pos = i * 3;
        if (!isxdigit((unsigned char)mac_str[pos]) ||
            !isxdigit((unsigned char)mac_str[pos + 1])) {
            return -1;
        }
        if (i < MAC_OCTETS - 1 && mac_str[pos + 2] != sep) {
            return -1;
        }
    }

    /* 解析数值 */
    for (int i = 0; i < MAC_OCTETS; i++) {
        unsigned int byte;
        if (sscanf(mac_str + i * 3, "%2x", &byte) != 1) {
            return -1;
        }
        mac_out[i] = (uint8_t)byte;
    }

    return 0;
}

/**
 * 构建并发送 Wake-on-LAN 魔法包
 * 
 * @param mac      6字节目标MAC地址
 * @param ip_str   目标IP地址字符串
 * @param port     目标端口
 */
static void send_wol_packet(const uint8_t *mac, const char *ip_str, int port)
{
    uint8_t packet[WOL_PKT_SIZE];
    struct sockaddr_in addr;
    int sock;
    int opt = 1;

    /* 构建魔法包: 6字节0xFF + 16次重复MAC */
    memset(packet, 0xFF, MAC_OCTETS);
    for (int i = 0; i < MAC_REPEAT; i++) {
        memcpy(packet + MAC_OCTETS + (i * MAC_OCTETS), mac, MAC_OCTETS);
    }

    /* 创建 UDP socket */
    sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        die("创建 socket 失败");
    }

    /* Windows 下 setsockopt 需要 const char* 类型 */
    #ifdef _WIN32
        char opt_val = (char)opt;
    #else
        int opt_val = opt;
    #endif

    /* 启用广播 */
    if (setsockopt(sock, SOL_SOCKET, SO_BROADCAST,
                   &opt_val, sizeof(opt_val)) < 0) {
        CLOSE_SOCKET(sock);
        die("设置广播选项失败");
    }

    /* 设置目标地址 */
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip_str, &addr.sin_addr) != 1) {
        CLOSE_SOCKET(sock);
        die("无效的IP地址格式");
    }

    /* 发送魔法包 */
    int sent = sendto(sock, (const char *)packet, WOL_PKT_SIZE, 0,
                      (struct sockaddr *)&addr, sizeof(addr));
    if (sent < 0) {
        CLOSE_SOCKET(sock);
        die("发送数据包失败");
    }

    CLOSE_SOCKET(sock);
}

int main(int argc, char *argv[])
{
    uint8_t mac[MAC_OCTETS];
    const char *ip_str = "255.255.255.255";
    int port = WOL_PORT_DEFAULT;
    char mac_upper[MAC_STR_LEN + 1];

#ifdef _WIN32
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        die("初始化 Winsock 失败");
    }
#endif

    if (argc < 2) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    /* 复制并转换为大写，统一处理 */
    size_t mac_len = strlen(argv[1]);
    if (mac_len > MAC_STR_LEN) {
        die("MAC地址过长");
    }
    for (size_t i = 0; i < mac_len; i++) {
        mac_upper[i] = (char)toupper((unsigned char)argv[1][i]);
    }
    mac_upper[mac_len] = '\0';

    /* 解析MAC地址 */
    if (parse_mac(mac_upper, mac) != 0) {
        die("MAC地址格式错误 (应为 AA:BB:CC:DD:EE:FF 或 AA-BB-CC-DD-EE-FF)");
    }

    /* 校验 MAC 地址：不能全零或多播 */
    int all_zero = 1;
    int i;
    for (i = 0; i < MAC_OCTETS; i++) {
        if (mac[i] != 0x00) { all_zero = 0; break; }
    }
    if (all_zero) { die("MAC 地址不能全为零"); }
    if (mac[0] & 0x01) { die("MAC 地址不能是多播地址"); }

    /* 解析可选参数 */
    if (argc > 2) {
        ip_str = argv[2];
    }
    if (argc > 3) {
        char *endptr;
        long p = strtol(argv[3], &endptr, 10);
        if (*endptr != '\0' || p <= 0 || p > 65535) {
            die("端口号无效 (应为 1-65535)");
        }
        port = (int)p;
    }

    /* 发送WOL数据包 */
    send_wol_packet(mac, ip_str, port);

    printf("WOL 魔法包已发送至 %02X:%02X:%02X:%02X:%02X:%02X (目标: %s:%d)\n",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], ip_str, port);

#ifdef _WIN32
    WSACleanup();
#endif

    return EXIT_SUCCESS;
}
