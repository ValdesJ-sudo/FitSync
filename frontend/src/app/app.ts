import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { WorkoutStorageService } from './core/workout/workout-storage.service';
import { WorkoutSession, WorkoutSet } from './core/workout/workout.models';

type AppView = 'home' | 'history';

const EXERCISES = [
  'Press de banca',
  'Sentadilla con barra',
  'Peso muerto',
  'Press militar',
  'Remo con barra',
  'Jalón al pecho',
  'Prensa de piernas',
  'Curl de bíceps',
  'Extensión de tríceps',
  'Plancha',
];

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, FormsModule],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  readonly workoutStore = inject(WorkoutStorageService);
  readonly today = new Date();
  readonly view = signal<AppView>('home');
  readonly showExercisePicker = signal(false);
  readonly exerciseSearch = signal('');
  readonly customExerciseName = signal('');
  readonly workoutName = signal('');
  readonly selectedExerciseNames = signal<string[]>(EXERCISES);
  readonly activeWorkout = this.workoutStore.activeWorkout;
  readonly sessions = this.workoutStore.sessions;
  readonly storageError = this.workoutStore.storageError;
  readonly validationError = this.workoutStore.validationError;

  readonly filteredExercises = computed(() => {
    const search = this.exerciseSearch().trim().toLocaleLowerCase('es');
    return this.selectedExerciseNames().filter((name) =>
      name.toLocaleLowerCase('es').includes(search),
    );
  });
  readonly thisWeekCount = computed(
    () => this.sessions().filter((session) => this.isInCurrentWeek(session.startedAt)).length,
  );
  readonly thisMonthCount = computed(
    () =>
      this.sessions().filter((session) => {
        const date = new Date(session.startedAt);
        const now = new Date();
        return date.getMonth() === now.getMonth() && date.getFullYear() === now.getFullYear();
      }).length,
  );
  readonly totalSets = computed(() =>
    this.sessions().reduce(
      (count, session) =>
        count + session.exercises.reduce((exerciseCount, exercise) => exerciseCount + exercise.sets.length, 0),
      0,
    ),
  );
  readonly recentSessions = computed(() => this.sessions().slice(0, 3));

  startWorkout(): void {
    this.workoutStore.startWorkout(this.workoutName());
    this.workoutName.set('');
    if (this.activeWorkout()) {
      this.showExercisePicker.set(true);
    }
  }

  addExercise(name: string): void {
    this.workoutStore.addExercise(name);
    if (!this.storageError()) {
      this.showExercisePicker.set(false);
      this.exerciseSearch.set('');
      this.customExerciseName.set('');
    }
  }

  addCustomExercise(): void {
    const name = this.customExerciseName().trim();
    if (!name) {
      return;
    }
    this.addExercise(name);
    if (!this.storageError()) {
      this.selectedExerciseNames.update((names) =>
        names.includes(name) ? names : [name, ...names],
      );
    }
  }

  updateSet(
    exerciseId: string,
    setId: string,
    field: 'reps' | 'weightKg',
    value: number | null,
  ): void {
    this.workoutStore.updateSet(exerciseId, setId, field, value);
  }

  updateWorkoutName(name: string): void {
    this.workoutStore.renameActiveWorkout(name);
  }

  updateNotes(notes: string): void {
    this.workoutStore.updateNotes(notes);
  }

  finishWorkout(): void {
    this.workoutStore.finishWorkout();
    if (!this.activeWorkout()) {
      this.view.set('history');
      this.showExercisePicker.set(false);
    }
  }

  discardWorkout(): void {
    if (globalThis.confirm('¿Descartar este entrenamiento? No se podrá recuperar.')) {
      this.workoutStore.discardActiveWorkout();
      this.showExercisePicker.set(false);
    }
  }

  totalWorkoutSets(session: WorkoutSession): number {
    return session.exercises.reduce((total, exercise) => total + exercise.sets.length, 0);
  }

  totalWorkoutVolume(session: WorkoutSession): number {
    return session.exercises.reduce(
      (total, exercise) =>
        total +
        exercise.sets.reduce(
          (exerciseTotal, set) =>
            exerciseTotal + (set.reps ?? 0) * (set.weightKg ?? 0),
          0,
        ),
      0,
    );
  }

  workoutDuration(session: WorkoutSession): number {
    const end = session.endedAt ? new Date(session.endedAt) : new Date();
    const duration = Math.round((end.getTime() - new Date(session.startedAt).getTime()) / 60_000);
    return session.endedAt ? Math.max(1, duration) : Math.max(0, duration);
  }

  exerciseCountLabel(session: WorkoutSession): string {
    const count = session.exercises.length;
    return `${count} ${count === 1 ? 'ejercicio' : 'ejercicios'}`;
  }

  exerciseSetLabel(set: WorkoutSet): string {
    const reps = set.reps === null ? '—' : `${set.reps} rep`;
    const weight = set.weightKg === null ? 'sin peso' : `${set.weightKg} kg`;
    return `${reps} · ${weight}`;
  }

  private isInCurrentWeek(isoDate: string): boolean {
    const date = new Date(isoDate);
    const now = new Date();
    const monday = new Date(now);
    monday.setHours(0, 0, 0, 0);
    monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7));
    return date >= monday && date <= now;
  }
}
