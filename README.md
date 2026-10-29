# FitSync

Aplicación para registrar entrenamientos personales y, en una etapa posterior, incorporar gimnasios como una capa opcional.

## Frontend

La primera versión de la interfaz está en `frontend/` y usa Angular standalone. Permite iniciar una sesión, añadir ejercicios, registrar series con repeticiones y peso, finalizarla y consultar el historial. Las sesiones activas y completadas se guardan en el almacenamiento local del navegador; todavía no se sincronizan entre dispositivos ni con un backend.

### Ejecutar

Requisitos: Node.js 22.22.3+, 24.15+ o 26+, y npm.

```powershell
cd frontend
npm.cmd install
npm.cmd start
```

La aplicación estará disponible en `http://localhost:4200`. Para compilarla:

```powershell
npm.cmd run build
```

Las pruebas del registro de entrenamientos se ejecutan con:

```powershell
npx.cmd ng test --watch=false --include=src/app/core/workout/workout-storage.service.spec.ts
```

La suite completa todavía contiene archivos `*.spec.ts` vacíos del esqueleto inicial, por lo que Vitest informa errores de “No test suite found” al ejecutarla sin filtros.

## Arquitectura prevista

- `frontend/`: Angular para la experiencia de usuario.
- `backend/`: FastAPI para la API de la aplicación.
- `supabase/`: PostgreSQL, autenticación y políticas RLS.

El esquema inicial de Supabase se encuentra en `supabase/migrations/`. La conexión con FastAPI y Supabase se incorporará en una siguiente etapa; el frontend actual no requiere credenciales ni configura acceso remoto.
