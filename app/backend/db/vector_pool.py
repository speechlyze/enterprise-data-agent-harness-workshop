"""vector_memory_size management. Mirrors notebook §3.2.1 (with the
CDB-vs-PDB scope fix from later in the session).

vector_memory_size is a static instance-wide parameter — setting it requires
SPFILE scope + a database bounce. We always set it at the CDB root (CONTAINER=ALL)
because PDB scope doesn't actually allocate the SGA pool.
"""

import oracledb


def get_running_mb(sys_conn) -> int:
    """Return the live vector_memory_size in MB (0 if pool isn't allocated)."""
    with sys_conn.cursor() as cur:
        cur.execute(
            "SELECT NVL(value, '0') FROM v$parameter WHERE name = 'vector_memory_size'"
        )
        row = cur.fetchone()
    return int(row[0] or 0) // (1024 * 1024) if row else 0


def get_spfile_mb(sys_conn) -> int:
    """Return the SPFILE-stored vector_memory_size in MB."""
    with sys_conn.cursor() as cur:
        cur.execute(
            "SELECT NVL(value, '0') FROM v$spparameter WHERE name = 'vector_memory_size'"
        )
        row = cur.fetchone()
    return int(row[0] or 0) // (1024 * 1024) if row else 0


def set_spfile(sys_conn, size_mb: int = 512):
    """Set vector_memory_size in the SPFILE at CDB-root scope.
    Takes effect on the next instance bounce.
    """
    with sys_conn.cursor() as cur:
        # Defensive RESET in case a previous PDB-scoped value is lingering
        try:
            cur.execute("ALTER SYSTEM RESET vector_memory_size SCOPE=SPFILE")
        except oracledb.DatabaseError:
            pass
        cur.execute(
            f"ALTER SYSTEM SET vector_memory_size = {size_mb}M "
            "SCOPE=SPFILE CONTAINER=ALL"
        )
    sys_conn.commit()


def needs_bounce(sys_conn, target_mb: int = 512) -> bool:
    """True if SPFILE has the right value but the running instance hasn't picked it up."""
    return get_running_mb(sys_conn) < target_mb <= get_spfile_mb(sys_conn)
