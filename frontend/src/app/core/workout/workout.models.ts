export interface WorkoutSet {
  id: string;
  reps: number | null;
  weightKg: number | null;
}

export interface WorkoutExercise {
  id: string;
  name: string;
  sets: WorkoutSet[];
}

export interface WorkoutSession {
  id: string;
  name: string;
  startedAt: string;
  endedAt: string | null;
  notes: string;
  exercises: WorkoutExercise[];
}

export interface StoredWorkoutData {
  version: 1;
  activeWorkout: WorkoutSession | null;
  sessions: WorkoutSession[];
}
