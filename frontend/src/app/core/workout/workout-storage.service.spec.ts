import { TestBed } from '@angular/core/testing';
import { WorkoutStorageService } from './workout-storage.service';

describe('WorkoutStorageService', () => {
  let service: WorkoutStorageService;

  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({ providers: [WorkoutStorageService] });
    service = TestBed.inject(WorkoutStorageService);
  });

  it('persists an active workout, its sets, and the completed session', () => {
    service.startWorkout('Día de piernas');
    const active = service.activeWorkout();
    expect(active?.name).toBe('Día de piernas');

    service.addExercise('Sentadilla con barra');
    const exercise = service.activeWorkout()?.exercises[0];
    expect(exercise?.sets).toHaveLength(1);

    service.updateSet(exercise!.id, exercise!.sets[0].id, 'reps', 10);
    service.updateSet(exercise!.id, exercise!.sets[0].id, 'weightKg', 40);
    service.addSet(exercise!.id);
    service.updateNotes('Buena sesión');
    service.finishWorkout();

    expect(service.activeWorkout()).toBeNull();
    expect(service.sessions()).toHaveLength(1);
    expect(service.sessions()[0].exercises[0].sets).toHaveLength(2);
    expect(service.sessions()[0].exercises[0].sets[0]).toMatchObject({
      reps: 10,
      weightKg: 40,
    });
    expect(service.sessions()[0].notes).toBe('Buena sesión');
    expect(service.storageError()).toBeNull();

    TestBed.resetTestingModule();
    TestBed.configureTestingModule({ providers: [WorkoutStorageService] });
    const reloadedService = TestBed.inject(WorkoutStorageService);
    expect(reloadedService.sessions()).toEqual(service.sessions());
  });

  it('reports malformed saved data and allows the user to clear it', () => {
    localStorage.setItem('fitsync.workouts.v1', '{invalid');
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({ providers: [WorkoutStorageService] });
    service = TestBed.inject(WorkoutStorageService);

    expect(service.storageError()).toContain('no se pudieron leer');

    service.clearLocalData();
    expect(service.storageError()).toBeNull();
    expect(localStorage.getItem('fitsync.workouts.v1')).toBeNull();
  });

  it('restores an in-progress session after the service is recreated', () => {
    service.startWorkout('Día de espalda');
    service.addExercise('Remo con barra');
    const activeExercise = service.activeWorkout()?.exercises[0];
    expect(activeExercise).toBeDefined();
    if (!activeExercise) {
      return;
    }

    service.updateSet(activeExercise.id, activeExercise.sets[0].id, 'reps', 8);
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({ providers: [WorkoutStorageService] });
    const restoredService = TestBed.inject(WorkoutStorageService);

    expect(restoredService.activeWorkout()?.name).toBe('Día de espalda');
    expect(restoredService.activeWorkout()?.exercises[0].sets[0].reps).toBe(8);
  });
});
