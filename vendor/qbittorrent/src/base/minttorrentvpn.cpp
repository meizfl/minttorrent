/* MintTorrent's in-process AmneziaWG/gVisor runtime control. */
#include "minttorrentvpn.h"

#include <mutex>

#include <QFile>
#include <QFileInfo>
#include <QCoreApplication>
#include <QDir>
#include <QSaveFile>
#include <QVariant>

#include <libtorrent/aux_/minttorrent_awg_api.h>

#include "logger.h"
#include "profile.h"
#include "path.h"
#include "settingsstorage.h"

using namespace Qt::Literals::StringLiterals;

namespace
{
    const auto KEY_ENABLED = u"MintTorrent/VPN/Enabled"_s;
    const auto KEY_IPV4 = u"MintTorrent/VPN/IPv4"_s;
    const auto KEY_IPV6 = u"MintTorrent/VPN/IPv6"_s;
    const auto KEY_MTU = u"MintTorrent/Netstack/MTU"_s;
    const auto KEY_QUEUE = u"MintTorrent/Netstack/PacketQueue"_s;
    const auto KEY_SEND = u"MintTorrent/Netstack/TCPSendBuffer"_s;
    const auto KEY_RECEIVE = u"MintTorrent/Netstack/TCPReceiveBuffer"_s;
    constexpr qsizetype MAX_PROFILE_SIZE = 128 * 1024;
    constexpr int ERROR_CAP = 1024;
    std::mutex runtimeMutex;
    long long stackHandle = -1;

    QString profilePath()
    {
        return (Profile::instance()->location(SpecialFolder::Config) / Path(u"minttorrent-awg.conf"_s)).toString();
    }

    QString errorText(const char *error)
    {
        return QString::fromUtf8(error);
    }

    void stopLocked()
    {
        if (stackHandle < 0)
            return;

        char error[ERROR_CAP] {};
        const long long oldHandle = stackHandle;
        stackHandle = -1;
        if (mt_stack_close(oldHandle, error, ERROR_CAP) != 0)
            LogMsg(u"MintTorrent: failed to stop userspace VPN stack: %1"_s.arg(errorText(error)), Log::CRITICAL);
    }

    bool startLocked(const QByteArray &profile, const bool ipv4, const bool ipv6, int mtu, int queue, int send, int receive, QString *errorMessage)
    {
        if (!ipv4 && !ipv6)
        {
            if (errorMessage)
                *errorMessage = u"At least one IP family must be enabled"_s;
            return false;
        }
        if (profile.isEmpty() || (profile.size() > MAX_PROFILE_SIZE) || profile.contains('\0'))
        {
            if (errorMessage)
                *errorMessage = u"VPN profile is empty, too large, or contains a NUL byte"_s;
            return false;
        }

        stopLocked();
        QByteArray mutableProfile = profile;
        char error[ERROR_CAP] {};
        const long long handle = mt_stack_open_configured(mutableProfile.data(), ipv4 ? 1 : 0, ipv6 ? 1 : 0, mtu, queue, send, receive, error, ERROR_CAP);
        if (handle < 0)
        {
            if (errorMessage)
                *errorMessage = errorText(error);
            return false;
        }

        if (mt_stack_set_default(handle, error, ERROR_CAP) != 0)
        {
            mt_stack_close(handle, error, ERROR_CAP);
            if (errorMessage)
                *errorMessage = errorText(error);
            return false;
        }
        stackHandle = handle;
        return true;
    }

    bool writeProfile(const QByteArray &profile, QString *errorMessage)
    {
        QSaveFile file(profilePath());
        if (!file.open(QIODevice::WriteOnly))
        {
            if (errorMessage)
                *errorMessage = file.errorString();
            return false;
        }
        file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        if ((file.write(profile) != profile.size()) || !file.commit())
        {
            if (errorMessage)
                *errorMessage = file.errorString();
            return false;
        }
        QFile::setPermissions(profilePath(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        return true;
    }
}

bool MintTorrentVPN::startSavedProfile(QString *errorMessage)
{
    std::lock_guard lock(runtimeMutex);
    // The launcher resolves the operator's TOML and supplies an explicit
    // first-run profile source. A profile imported through the WebUI lives in
    // the qBittorrent profile and is never replaced once present.
    // The bundle ships a first-run profile. Copy it into qBittorrent's active
    // profile directory once; never replace a profile the user has imported.
    const QString activePath = profilePath();
    if (!QFileInfo::exists(activePath))
    {
        QString sourcePath = qEnvironmentVariable("MINTTORRENT_VPN_CONFIG");
        if (sourcePath.isEmpty())
            sourcePath = QDir(QCoreApplication::applicationDirPath()).filePath(u"../config/vpn/default.conf"_s);
        QFile bundledProfile(sourcePath);
        if (bundledProfile.open(QIODevice::ReadOnly)
            && (bundledProfile.size() > 0) && (bundledProfile.size() <= MAX_PROFILE_SIZE))
        {
            QSaveFile activeProfile(activePath);
            if (!activeProfile.open(QIODevice::WriteOnly))
            {
                if (errorMessage)
                    *errorMessage = activeProfile.errorString();
                return false;
            }
            activeProfile.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
            const QByteArray bundledData = bundledProfile.readAll();
            if ((activeProfile.write(bundledData) != bundledData.size()) || !activeProfile.commit())
            {
                if (errorMessage)
                    *errorMessage = activeProfile.errorString();
                return false;
            }
            QFile::setPermissions(activePath, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        }
    }

    if (qEnvironmentVariableIsSet("MINTTORRENT_VPN_AUTOSTART"))
    {
        const bool autoStart = (qEnvironmentVariable("MINTTORRENT_VPN_AUTOSTART").compare(u"true"_s, Qt::CaseInsensitive) == 0);
        SettingsStorage::instance()->storeValue(KEY_ENABLED, autoStart);
    }
    if (!SettingsStorage::instance()->loadValue<bool>(KEY_ENABLED, false))
        return true;

    QFile file(profilePath());
    if (!file.open(QIODevice::ReadOnly) || (file.size() <= 0) || (file.size() > MAX_PROFILE_SIZE))
    {
        if (errorMessage)
            *errorMessage = u"Saved VPN profile is missing or has an invalid size"_s;
        return false;
    }
    const QByteArray profile = file.readAll();
    const bool ipv4 = SettingsStorage::instance()->loadValue<bool>(KEY_IPV4, true);
    const bool ipv6 = SettingsStorage::instance()->loadValue<bool>(KEY_IPV6, true);
    return startLocked(profile, ipv4, ipv6,
        SettingsStorage::instance()->loadValue<int>(KEY_MTU, 0),
        SettingsStorage::instance()->loadValue<int>(KEY_QUEUE, 1024),
        SettingsStorage::instance()->loadValue<int>(KEY_SEND, 1048576),
        SettingsStorage::instance()->loadValue<int>(KEY_RECEIVE, 1048576), errorMessage);
}

QByteArray MintTorrentVPN::savedProfile(QString *errorMessage)
{
    std::lock_guard lock(runtimeMutex);
    QFile file(profilePath());
    if (!file.open(QIODevice::ReadOnly))
    {
        if (errorMessage)
            *errorMessage = file.errorString();
        return {};
    }
    if ((file.size() <= 0) || (file.size() > MAX_PROFILE_SIZE))
    {
        if (errorMessage)
            *errorMessage = u"Saved VPN profile is empty or has an invalid size"_s;
        return {};
    }
    return file.readAll();
}

bool MintTorrentVPN::importAndStart(const QByteArray &profile, const bool ipv4, const bool ipv6, const int mtu, const int queue, const int send, const int receive, QString *errorMessage)
{
    std::lock_guard lock(runtimeMutex);
    if ((mtu != 0) && ((mtu < 576) || (mtu > 9000))) { if (errorMessage) *errorMessage = u"MTU must be between 576 and 9000"_s; return false; }
    if ((queue < 64) || (queue > 16384) || (send < 16384) || (send > 16777216) || (receive < 16384) || (receive > 16777216)) { if (errorMessage) *errorMessage = u"Netstack values are outside supported ranges"_s; return false; }
    if (!writeProfile(profile, errorMessage))
        return false;

    SettingsStorage::instance()->storeValue(KEY_ENABLED, false);
    SettingsStorage::instance()->storeValue(KEY_IPV4, ipv4);
    SettingsStorage::instance()->storeValue(KEY_IPV6, ipv6);
    SettingsStorage::instance()->storeValue(KEY_MTU, mtu);
    SettingsStorage::instance()->storeValue(KEY_QUEUE, queue);
    SettingsStorage::instance()->storeValue(KEY_SEND, send);
    SettingsStorage::instance()->storeValue(KEY_RECEIVE, receive);
    if (!startLocked(profile, ipv4, ipv6, mtu, queue, send, receive, errorMessage))
    {
        SettingsStorage::instance()->save();
        return false;
    }

    SettingsStorage::instance()->storeValue(KEY_ENABLED, true);
    SettingsStorage::instance()->save();
    LogMsg(u"MintTorrent: userspace VPN stack is active"_s);
    return true;
}

bool MintTorrentVPN::setEnabled(const bool enabled, QString *errorMessage)
{
    std::lock_guard lock(runtimeMutex);
    if (!enabled)
    {
        stopLocked();
        SettingsStorage::instance()->storeValue(KEY_ENABLED, false);
        SettingsStorage::instance()->save();
        return true;
    }

    QFile file(profilePath());
    if (!file.open(QIODevice::ReadOnly) || (file.size() <= 0) || (file.size() > MAX_PROFILE_SIZE))
    {
        if (errorMessage)
            *errorMessage = u"Import a valid VPN profile before enabling the VPN"_s;
        return false;
    }
    const bool ipv4 = SettingsStorage::instance()->loadValue<bool>(KEY_IPV4, true);
    const bool ipv6 = SettingsStorage::instance()->loadValue<bool>(KEY_IPV6, true);
    if (!startLocked(file.readAll(), ipv4, ipv6,
        SettingsStorage::instance()->loadValue<int>(KEY_MTU, 0),
        SettingsStorage::instance()->loadValue<int>(KEY_QUEUE, 1024),
        SettingsStorage::instance()->loadValue<int>(KEY_SEND, 1048576),
        SettingsStorage::instance()->loadValue<int>(KEY_RECEIVE, 1048576), errorMessage))
        return false;

    SettingsStorage::instance()->storeValue(KEY_ENABLED, true);
    SettingsStorage::instance()->save();
    return true;
}

void MintTorrentVPN::stop()
{
    std::lock_guard lock(runtimeMutex);
    stopLocked();
}

QJsonObject MintTorrentVPN::status()
{
    std::lock_guard lock(runtimeMutex);
    const bool enabled = SettingsStorage::instance()->loadValue<bool>(KEY_ENABLED, false);
    const bool ipv4 = SettingsStorage::instance()->loadValue<bool>(KEY_IPV4, true);
    const bool ipv6 = SettingsStorage::instance()->loadValue<bool>(KEY_IPV6, true);
    const bool configured = QFileInfo::exists(profilePath());
    QJsonObject result {
        {u"enabled"_s, enabled},
        {u"configured"_s, configured},
        {u"profile_path"_s, profilePath()},
        {u"stack"_s, u"gVisor Netstack / AmneziaWG-Go"_s},
        {u"ipv4"_s, ipv4},
        {u"ipv6"_s, ipv6},
        {u"active"_s, stackHandle >= 0}
    };
    result.insert(u"mtu"_s, SettingsStorage::instance()->loadValue<int>(KEY_MTU, 0));
    result.insert(u"packet_queue"_s, SettingsStorage::instance()->loadValue<int>(KEY_QUEUE, 1024));
    result.insert(u"tcp_send_buffer"_s, SettingsStorage::instance()->loadValue<int>(KEY_SEND, 1048576));
    result.insert(u"tcp_receive_buffer"_s, SettingsStorage::instance()->loadValue<int>(KEY_RECEIVE, 1048576));

    if (stackHandle < 0)
        return result;

    long long handshake = 0;
    unsigned long long tx = 0;
    unsigned long long rx = 0;
    int peers = 0;
    char error[ERROR_CAP] {};
    if (mt_stack_status(stackHandle, &handshake, &tx, &rx, &peers, error, ERROR_CAP) == 0)
    {
        result.insert(u"last_handshake_ns"_s, static_cast<qint64>(handshake));
        result.insert(u"tx_bytes"_s, static_cast<qint64>(tx));
        result.insert(u"rx_bytes"_s, static_cast<qint64>(rx));
        result.insert(u"peers"_s, peers);
    }
    else
    {
        result.insert(u"error"_s, errorText(error));
    }

    int healthOk = 0;
    long long healthCheckedAt = 0;
    char healthMessage[512] {};
    if (mt_stack_health_status(stackHandle, &healthOk, &healthCheckedAt, healthMessage, sizeof(healthMessage), error, ERROR_CAP) == 0)
    {
        result.insert(u"data_path_healthy"_s, healthOk != 0);
        result.insert(u"health_checked_at_ns"_s, static_cast<qint64>(healthCheckedAt));
        result.insert(u"health_error"_s, errorText(healthMessage));
    }
    else
    {
        result.insert(u"data_path_healthy"_s, false);
        result.insert(u"health_error"_s, errorText(error));
    }

    char addresses[4096] {};
    if (mt_stack_addresses(stackHandle, addresses, sizeof(addresses), error, ERROR_CAP) >= 0)
        result.insert(u"addresses"_s, QString::fromUtf8(addresses));
    return result;
}
