<?php
/**
 * Стартовая страница шаблона: проверяет, что окружение собрано корректно.
 * Замените её кодом приложения — этот файл не является частью проекта.
 */

declare(strict_types=1);

/** Проверка соединения с MariaDB. */
function checkDatabase(): array
{
    try {
        $dsn = sprintf(
            'mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4',
            getenv('DB_HOST') ?: 'mariadb',
            getenv('DB_PORT') ?: '3306',
            getenv('DB_DATABASE') ?: 'app',
        );
        $pdo = new PDO($dsn, getenv('DB_USERNAME') ?: 'app', getenv('DB_PASSWORD') ?: '', [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_TIMEOUT => 3,
        ]);

        return [true, 'MariaDB ' . $pdo->getAttribute(PDO::ATTR_SERVER_VERSION)];
    } catch (Throwable $e) {
        return [false, $e->getMessage()];
    }
}

/** Проверка соединения с Redis. */
function checkRedis(): array
{
    if (!extension_loaded('redis')) {
        return [false, 'расширение redis не загружено'];
    }

    try {
        $redis = new Redis();
        $redis->connect(getenv('REDIS_HOST') ?: 'redis', (int) (getenv('REDIS_PORT') ?: 6379), 3.0);
        $pong = $redis->ping();

        return [$pong !== false, 'Redis отвечает'];
    } catch (Throwable $e) {
        return [false, $e->getMessage()];
    }
}

/**
 * Реальная проверка записи: is_writable() смотрит только на права,
 * а на практике мешают ещё владелец каталога, SELinux и опции монтирования.
 * Поэтому пробуем создать и удалить файл.
 */
function checkWritable(string $path): array
{
    if (!is_dir($path)) {
        return [false, 'каталога нет'];
    }

    $probe = $path . '/.write-test-' . getmypid();
    if (@file_put_contents($probe, 'ok') === false) {
        $owner = function_exists('posix_getpwuid')
            ? (posix_getpwuid(fileowner($path))['name'] ?? fileowner($path))
            : fileowner($path);

        return [false, sprintf('нет записи (владелец: %s, права: %o)', $owner, fileperms($path) & 0777)];
    }
    @unlink($probe);

    return [true, 'запись работает'];
}

/** Пользователь, от которого выполняется PHP-процесс. */
function currentUser(): string
{
    if (!function_exists('posix_geteuid')) {
        return get_current_user();
    }
    $uid = posix_geteuid();
    $name = posix_getpwuid($uid)['name'] ?? '?';

    return sprintf('%s (UID %d)', $name, $uid);
}

$root = dirname(__DIR__);

$checks = [
    'PHP'     => [true, PHP_VERSION],
    'MariaDB' => checkDatabase(),
    'Redis'   => checkRedis(),
];

$paths = [
    'storage/logs'   => checkWritable($root . '/storage/logs'),
    'storage/cache'  => checkWritable($root . '/storage/cache'),
    'public/uploads' => checkWritable($root . '/public/uploads'),
];

$allOk = array_reduce(
    array_merge(array_values($checks), array_values($paths)),
    static fn (bool $c, array $r): bool => $c && $r[0],
    true,
);
$permsOk = array_reduce($paths, static fn (bool $c, array $r): bool => $c && $r[0], true);
?>
<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Окружение готово</title>
    <style>
        :root { color-scheme: light dark; }
        body {
            margin: 0; min-height: 100vh; display: grid; place-items: center;
            font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
            background: Canvas; color: CanvasText;
        }
        main { width: min(90vw, 34rem); padding: 2rem; }
        h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
        h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .08em; opacity: .5; margin: 2rem 0 .5rem; }
        p.lead { margin: 0 0 1rem; opacity: .7; }
        p.note { margin: 0 0 .5rem; font-size: .875rem; opacity: .7; }
        p.hint {
            margin: 0 0 2rem; padding: .875rem 1rem; font-size: .875rem; line-height: 1.5;
            border-left: 3px solid #dc2626;
            background: color-mix(in srgb, #dc2626 8%, transparent);
        }
        ul { list-style: none; margin: 0 0 1rem; padding: 0; }
        li {
            display: flex; justify-content: space-between; gap: 1rem;
            padding: .75rem 0; border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent);
        }
        .status { font-variant-numeric: tabular-nums; opacity: .7; }
        .ok::before { content: "✓ "; color: #16a34a; }
        .fail::before { content: "✗ "; color: #dc2626; }
        footer { font-size: .875rem; opacity: .6; }
        code { background: color-mix(in srgb, CanvasText 10%, transparent); padding: .1em .4em; border-radius: 4px; }
    </style>
</head>
<body>
<main>
    <h1><?= $allOk ? 'Окружение готово к работе' : 'Окружение подняли, но есть проблемы' ?></h1>
    <p class="lead">Это страница-заглушка шаблона. Замените её кодом приложения.</p>

    <h2>Сервисы</h2>
    <ul>
        <?php foreach ($checks as $name => [$ok, $detail]): ?>
            <li>
                <span class="<?= $ok ? 'ok' : 'fail' ?>"><?= htmlspecialchars($name) ?></span>
                <span class="status"><?= htmlspecialchars($detail) ?></span>
            </li>
        <?php endforeach; ?>
    </ul>

    <h2>Права на запись</h2>
    <p class="note">PHP работает от <code><?= htmlspecialchars(currentUser()) ?></code></p>
    <ul>
        <?php foreach ($paths as $name => [$ok, $detail]): ?>
            <li>
                <span class="<?= $ok ? 'ok' : 'fail' ?>"><?= htmlspecialchars($name) ?></span>
                <span class="status"><?= htmlspecialchars($detail) ?></span>
            </li>
        <?php endforeach; ?>
    </ul>

    <?php if (!$permsOk): ?>
        <p class="hint">
            PHP не может писать в эти каталоги — обычно потому, что UID внутри контейнера
            не совпадает с владельцем файлов на хосте. Лечится командой
            <code>make fix-perms</code>; если не помогло — <code>make init &amp;&amp; make rebuild</code>.
        </p>
    <?php endif; ?>

    <footer>
        Код приложения — в <code>src/</code>, корень веб-сервера — <code>src/public/</code>.
        Команды: <code>make help</code>.
    </footer>
</main>
</body>
</html>
