/*
 * Bittorrent Client using Qt and libtorrent.
 * Copyright (C) 2018-2024  Vladimir Golovnev <glassez@yandex.ru>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 * In addition, as a special exception, the copyright holders give permission to
 * link this program with the OpenSSL project's "OpenSSL" library (or with
 * modified versions of it that use the same license as the "OpenSSL" library),
 * and distribute the linked executables. You must obey the GNU General Public
 * License in all respects for all of the code used other than "OpenSSL".  If you
 * modify file(s), you may extend this exception to your version of the file(s),
 * but you are not obligated to do so. If you do not wish to do so, delete this
 * exception statement from your version.
 */

#include "searchdownloadhandler.h"

#include <QtLogging>
#include <QProcess>
#include <QTimer>
#ifdef Q_OS_LINUX
#include <cerrno>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <cstddef>
#endif

#include "base/global.h"
#include "base/logger.h"
#include "base/path.h"
#include "base/utils/foreignapps.h"
#include "base/utils/fs.h"
#include "searchpluginmanager.h"

SearchDownloadHandler::SearchDownloadHandler(const QString &pluginName, const QString &url, SearchPluginManager *manager)
    : QObject(manager)
    , m_pluginName {pluginName}
    , m_url {url}
    , m_manager {manager}
    , m_downloadProcess {new QProcess(this)}
{
    m_downloadProcess->setProcessEnvironment(m_manager->proxyEnvironment());
#ifdef Q_OS_UNIX
    m_downloadProcess->setUnixProcessParameters(QProcess::UnixProcessFlag::CloseFileDescriptors);
#ifdef Q_OS_LINUX
    m_downloadProcess->setChildProcessModifier([]
    {
        sock_filter filter[] = {
            BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, 1),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socketpair, 0, 1),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_connect, 0, 1),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_io_uring_setup, 0, 1),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
        };
        sock_fprog program {static_cast<unsigned short>(std::size(filter)), filter};
        if ((prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
            || (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0))
            _exit(127);
    });
#endif
#endif
    connect(m_downloadProcess, qOverload<int, QProcess::ExitStatus>(&QProcess::finished)
            , this, &SearchDownloadHandler::downloadProcessFinished);
    const QStringList params
    {
        Utils::ForeignApps::PYTHON_ISOLATE_MODE_FLAG,
        Utils::ForeignApps::PYTHON_UTF8_MODE_FLAG,
        (SearchPluginManager::engineLocation() / Path(u"nova2dl.py"_s)).toString(),
        pluginName,
        url
    };
    // Launch search
#if defined(TORRENT_USE_MINTTORRENT_NETSTACK) && !defined(Q_OS_LINUX)
    QTimer::singleShot(0, this, [this]
    {
        emit downloadFinished({}, tr("Search plugins are disabled: no host-network sandbox is available on this platform."));
    });
#else
    m_downloadProcess->start(Utils::ForeignApps::pythonInfo().executablePath.data(), params, QIODevice::ReadOnly);
#endif
}

void SearchDownloadHandler::downloadProcessFinished(const int exitcode)
{
    const auto errMsg = QString::fromUtf8(m_downloadProcess->readAllStandardError()).trimmed();
    if (!errMsg.isEmpty())
    {
        qWarning("%s", qUtf8Printable(errMsg));
        LogMsg(tr("Error occurred when downloading torrent via search engine. Engine: \"%1\". URL: \"%2\". Error: \"%3\".")
            .arg(m_pluginName, m_url, errMsg), Log::WARNING);
    }

    QString path;
    if ((exitcode == 0) && (m_downloadProcess->exitStatus() == QProcess::NormalExit))
    {
        const QString line = QString::fromUtf8(m_downloadProcess->readAllStandardOutput()).trimmed();
        const QList<QStringView> parts = QStringView(line).split(u' ');
        if (parts.size() == 2)
            path = parts[0].toString();
    }

    emit downloadFinished(path, errMsg);
}
