/* MintTorrent's in-process AmneziaWG/gVisor runtime control. */
#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QString>

namespace MintTorrentVPN
{
    bool startSavedProfile(QString *error = nullptr);
    bool importAndStart(const QByteArray &profile, bool ipv4, bool ipv6, int mtu, int packetQueue, int tcpSendBuffer, int tcpReceiveBuffer, QString *error = nullptr);
    bool setEnabled(bool enabled, QString *error = nullptr);
    void stop();
    QJsonObject status();
    QByteArray savedProfile(QString *error = nullptr);
}
