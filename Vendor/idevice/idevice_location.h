#pragma once

#include <stddef.h>
#include <sys/socket.h>

typedef struct IdeviceFfiError IdeviceFfiError;
void idevice_error_free(IdeviceFfiError *error);

typedef struct RpPairingFileHandle RpPairingFileHandle;
IdeviceFfiError *rp_pairing_file_read(const char *path, RpPairingFileHandle **out_handle);
void rp_pairing_file_free(RpPairingFileHandle *handle);

typedef const char *(*IdevicePinCallback)(void *context);

typedef struct AdapterHandle AdapterHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;
typedef struct RemoteServerHandle RemoteServerHandle;
typedef struct LocationSimulationHandle LocationSimulationHandle;

IdeviceFfiError *tunnel_create_rppairing(
    const struct sockaddr *address,
    socklen_t address_length,
    const char *hostname,
    RpPairingFileHandle *pairing_file,
    IdevicePinCallback pin_callback,
    void *pin_context,
    AdapterHandle **out_adapter,
    RsdHandshakeHandle **out_handshake
);
void adapter_free(AdapterHandle *adapter);
void rsd_handshake_free(RsdHandshakeHandle *handshake);

IdeviceFfiError *remote_server_connect_rsd(
    AdapterHandle *adapter,
    RsdHandshakeHandle *handshake,
    RemoteServerHandle **out_server
);
void remote_server_free(RemoteServerHandle *server);

IdeviceFfiError *location_simulation_new(
    RemoteServerHandle *server,
    LocationSimulationHandle **out_simulation
);
void location_simulation_free(LocationSimulationHandle *simulation);
IdeviceFfiError *location_simulation_set(
    LocationSimulationHandle *simulation,
    double latitude,
    double longitude
);
IdeviceFfiError *location_simulation_clear(LocationSimulationHandle *simulation);
