# Distribuirani sustav za nadzor i etičko hakiranje mreže

Izvorni kod praktičnog dijela diplomskog rada Karla Ipse.

Sustav u izoliranom virtualnom laboratoriju povezuje središnji poslužitelj,
agente i NIDS. Obuhvaća nadzor čvorova i servisa, obradu ICMP napada,
oporavak sustava te TLS komunikaciju.

## Struktura

- `server/` – središnji poslužitelj
- `agent/` – agenti za nadzor
- `nids/` – mrežna detekcija
- `01-*.ps1` do `09-*.ps1` – skripte za eksperimente
- `tests/` – provjere obrade poruka

Sirovi rezultati, logovi i lokalno generirani certifikati nisu uključeni.
Projekt je namijenjen uporabi u izoliranom laboratoriju.