import { isPlatformBrowser } from '@angular/common';
import { inject, Injectable, PLATFORM_ID, signal } from '@angular/core';
import {
  StoredWorkoutData,
  WorkoutExercise,
  WorkoutSession,
  WorkoutSet,
} from './workout.models';

const STORAGE_KEY = 'fitsync.workouts.v1';

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isWorkoutSet(value: unknown): value is WorkoutSet {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value['id'] === 'string' &&
    (value['reps'] === null || typeof value['reps'] === 'number') &&
    (value['weightKg'] === null || typeof value['weightKg'] === 'number')
  );
}

function isWorkoutExercise(value: unknown): value is WorkoutExercise {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value['id'] === 'string' &&
    typeof value['name'] === 'string' &&
    Array.isArray(value['sets']) &&
    value['sets'].every(isWorkoutSet)
  );
}

function isWorkoutSession(value: unknown): value is WorkoutSession {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value['id'] === 'string' &&
    typeof value['name'] === 'string' &&
    typeof value['startedAt'] === 'string' &&
    (value['endedAt'] === null || typeof value['endedAt'] === 'string') &&
    typeof value['notes'] === 'string' &&
    Array.isArray(value['exercises']) &&
    value['exercises'].every(isWorkoutExercise)
  );
}

function isStoredWorkoutData(value: unknown): value is StoredWorkoutData {
  if (!isRecord(value)) {
    return false;
  }

  return (
    value['version'] === 1 &&
    (value['activeWorkout'] === null || isWorkoutSession(value['activeWorkout'])) &&
    Array.isArray(value['sessions']) &&
    value['sessions'].every(isWorkoutSession)
  );
}

function createId(): string {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

@Injectable({ providedIn: 'root' })
export class WorkoutStorageService {
  private readonly platformId = inject(PLATFORM_ID);
  private readonly activeWorkoutState = signal<WorkoutSession | null>(null);
  private readonly sessionsState = signal<WorkoutSession[]>([]);
  private storage: Storage | null = null;

  readonly activeWorkout = this.activeWorkoutState.asReadonly();
  readonly sessions = this.sessionsState.asReadonly();
  readonly storageError = signal<string | null>(null);
  readonly validationError = signal<string | null>(null);

  constructor() {
    if (!isPlatformBrowser(this.platformId)) {
      return;
    }

    try {
      this.storage = globalThis.localStorage;
      this.load();
    } catch {
      this.storageError.set(
        'No se pudo acceder al almacenamiento local del navegador. Revisa la configuración de privacidad.',
      );
    }
  }

  startWorkout(name: string): void {
    const now = new Date();
    const formattedDate = new Intl.DateTimeFormat('es', {
      day: 'numeric',
      month: 'long',
    }).format(now);
    const workout: WorkoutSession = {
      id: createId(),
      name: name.trim() || `Entrenamiento del ${formattedDate}`,
      startedAt: now.toISOString(),
      endedAt: null,
      notes: '',
      exercises: [],
    };

    this.commit(workout, this.sessionsState());
  }

  renameActiveWorkout(name: string): void {
    const active = this.activeWorkoutState();
    if (!active) {
      return;
    }
    this.commit({ ...active, name }, this.sessionsState());
  }

  updateNotes(notes: string): void {
    const active = this.activeWorkoutState();
    if (!active) {
      return;
    }
    this.commit({ ...active, notes }, this.sessionsState());
  }

  addExercise(name: string): void {
    const active = this.activeWorkoutState();
    const exerciseName = name.trim();
    if (!active || !exerciseName) {
      return;
    }

    const exercise: WorkoutExercise = {
      id: createId(),
      name: exerciseName,
      sets: [{ id: createId(), reps: null, weightKg: null }],
    };
    this.commit(
      { ...active, exercises: [...active.exercises, exercise] },
      this.sessionsState(),
    );
  }

  removeExercise(exerciseId: string): void {
    const active = this.activeWorkoutState();
    if (!active) {
      return;
    }
    this.commit(
      {
        ...active,
        exercises: active.exercises.filter((exercise) => exercise.id !== exerciseId),
      },
      this.sessionsState(),
    );
  }

  addSet(exerciseId: string): void {
    const active = this.activeWorkoutState();
    if (!active) {
      return;
    }

    const exercises = active.exercises.map((exercise) => {
      if (exercise.id !== exerciseId) {
        return exercise;
      }

      const previousSet = exercise.sets.at(-1);
      return {
        ...exercise,
        sets: [
          ...exercise.sets,
          {
            id: createId(),
            reps: previousSet?.reps ?? null,
            weightKg: previousSet?.weightKg ?? null,
          },
        ],
      };
    });
    this.commit({ ...active, exercises }, this.sessionsState());
  }

  updateSet(
    exerciseId: string,
    setId: string,
    field: 'reps' | 'weightKg',
    value: number | null,
  ): void {
    const active = this.activeWorkoutState();
    if (!active) {
      return;
    }
    if (
      value !== null &&
      (!Number.isFinite(value) || value < (field === 'reps' ? 1 : 0))
    ) {
      this.validationError.set(
        field === 'reps'
          ? 'Las repeticiones deben ser un número mayor que cero.'
          : 'El peso debe ser un número igual o mayor que cero.',
      );
      return;
    }

    const exercises = active.exercises.map((exercise) => ({
      ...exercise,
      sets: exercise.sets.map((set) =>
        exercise.id === exerciseId && set.id === setId
          ? { ...set, [field]: value }
          : set,
      ),
    }));
    this.commit({ ...active, exercises }, this.sessionsState());
  }

  finishWorkout(): void {
    const active = this.activeWorkoutState();
    if (!active) {
      return;
    }
    if (active.exercises.length === 0) {
      this.validationError.set('Añade al menos un ejercicio antes de finalizar.');
      return;
    }
    if (active.exercises.some((exercise) => exercise.sets.some((set) => set.reps === null))) {
      this.validationError.set('Completa las repeticiones de cada serie antes de finalizar.');
      return;
    }

    const finishedWorkout = { ...active, endedAt: new Date().toISOString() };
    this.commit(null, [finishedWorkout, ...this.sessionsState()]);
  }

  discardActiveWorkout(): void {
    if (this.activeWorkoutState()) {
      this.commit(null, this.sessionsState());
    }
  }

  clearLocalData(): void {
    try {
      this.storage?.removeItem(STORAGE_KEY);
      this.activeWorkoutState.set(null);
      this.sessionsState.set([]);
      this.storageError.set(null);
      this.validationError.set(null);
    } catch {
      this.storageError.set(
        'No se pudieron borrar los datos locales. Revisa la configuración del navegador.',
      );
    }
  }

  private load(): void {
    if (!this.storage) {
      this.storageError.set('El almacenamiento local no está disponible en este navegador.');
      return;
    }

    const savedData = this.storage.getItem(STORAGE_KEY);
    if (!savedData) {
      return;
    }

    let parsedData: unknown;
    try {
      parsedData = JSON.parse(savedData);
    } catch {
      this.storageError.set(
        'Los datos guardados no se pudieron leer. Puedes borrarlos para empezar de nuevo.',
      );
      return;
    }

    if (!isStoredWorkoutData(parsedData)) {
      this.storageError.set(
        'Los datos guardados tienen un formato no compatible. Puedes borrarlos para empezar de nuevo.',
      );
      return;
    }

    this.activeWorkoutState.set(parsedData.activeWorkout);
    this.sessionsState.set(parsedData.sessions);
  }

  private commit(
    activeWorkout: WorkoutSession | null,
    sessions: WorkoutSession[],
  ): void {
    if (!this.storage) {
      this.storageError.set('No se pudieron guardar los cambios en este navegador.');
      return;
    }

    const data: StoredWorkoutData = {
      version: 1,
      activeWorkout,
      sessions,
    };

    try {
      this.storage.setItem(STORAGE_KEY, JSON.stringify(data));
      this.activeWorkoutState.set(activeWorkout);
      this.sessionsState.set(sessions);
      this.storageError.set(null);
      this.validationError.set(null);
    } catch {
      this.storageError.set(
        'No se pudieron guardar los cambios. Comprueba el espacio disponible en el navegador.',
      );
    }
  }
}
