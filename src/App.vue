п»ї<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { exams as seedExams } from './data/exams'
import {
  loadLearningRecords,
  loadSprintResults,
  saveLearningRecords,
  saveSprintResult,
} from './lib/storage'
import { fetchAttempts, fetchExams, fetchUserStats, submitAttempt } from './lib/api'
import type { Attempt, Exam, ExamQuestion, LearningRecord, SprintResult } from './types'

type Tab = 'catalog' | 'leaderboard' | 'sprint' | 'learning'
type ReviewFilter = 'all' | 'wrong' | 'correct'
type Theme = 'light' | 'dark'
interface ExamReviewItem {
  questionNumber: number
  questionId: string
  topic: string
  prompt: string
  explanation: string
  scoreValue: number
  selectedText: string
  correctText: string
  isCorrect: boolean
}

interface ExamReview {
  attempt: Attempt
  examTitle: string
  passingScore: number
  scoringPoints: number
  maxScoringPoints: number
  correctCount: number
  total: number
  items: ExamReviewItem[]
}

const tab = ref<Tab>('catalog')
const storedUserName = localStorage.getItem('pet-user-name')?.trim() ?? ''
const userName = ref(storedUserName || 'Student')
const selectedSubject = ref('all')
const onboardingDone = ref(localStorage.getItem('pet-onboarding-done') === '1')
const onboardingName = ref(storedUserName)
const onboardingAccepted = ref(false)
const rawTheme = localStorage.getItem('pet-theme')
const theme = ref<Theme>(rawTheme === 'light' || rawTheme === 'dark' ? rawTheme : 'dark')

const attempts = ref<Attempt[]>([])
const sprintResults = ref<SprintResult[]>(loadSprintResults())
const learningRecords = ref<LearningRecord[]>(loadLearningRecords())
const examBank = ref<Exam[]>([])
const userStats = ref<Array<{ user_name: string; attempts_count: number; best_score: number; avg_score: number }>>([])

const activeExam = ref<Exam | null>(null)
const questionIndex = ref(0)
const answers = ref<Record<string, string>>({})
const examStartedAt = ref<number | null>(null)
const examElapsedSeconds = ref(0)
const lastAttempt = ref<Attempt | null>(null)
const examReview = ref<ExamReview | null>(null)
const reviewFilter = ref<ReviewFilter>('all')
const expandedReviewIds = ref<string[]>([])
const learningQueue = ref<LearningRecord[]>([])
const learningIndex = ref(0)
const learningSelectedOptionId = ref<string | null>(null)
const learningAnswered = ref(0)
const learningCorrect = ref(0)
const learningFinished = ref(false)

const sprintDurationSeconds = 60
const sprintActive = ref(false)
const sprintTimeLeft = ref(sprintDurationSeconds)
const sprintScore = ref(0)
const sprintAnswered = ref(0)
const sprintQuestion = ref<ExamQuestion | null>(null)

let examTimer: number | undefined
let sprintTimer: number | undefined

const allQuestions = computed(() => examBank.value.flatMap((exam) => exam.questions))
const subjects = computed(() => ['all', ...new Set(examBank.value.map((exam) => exam.subject))])

const filteredExams = computed(() => {
  if (selectedSubject.value === 'all') {
    return examBank.value
  }

  return examBank.value.filter((exam) => exam.subject === selectedSubject.value)
})

const currentQuestion = computed(() => {
  if (!activeExam.value) {
    return null
  }

  return activeExam.value.questions[questionIndex.value] ?? null
})

const committedAnsweredCount = computed(() => {
  if (!activeExam.value) {
    return 0
  }

  const committedIds = activeExam.value.questions.slice(0, questionIndex.value).map((question) => question.id)
  return committedIds.reduce((sum, questionId) => sum + (answers.value[questionId] ? 1 : 0), 0)
})

const progress = computed(() => {
  if (!activeExam.value) {
    return 0
  }

  return Math.round((committedAnsweredCount.value / activeExam.value.questions.length) * 100)
})

const examTimeLeft = computed(() => {
  if (!activeExam.value) {
    return 0
  }

  const total = activeExam.value.durationMinutes * 60
  return Math.max(total - examElapsedSeconds.value, 0)
})

const leaderboard = computed(() => {
  if (userStats.value.length) {
    return userStats.value.map((item) => ({
      name: item.user_name,
      best: item.best_score,
      avg: Math.round(item.avg_score),
      attempts: item.attempts_count,
    }))
  }

  const grouped = attempts.value.reduce<Record<string, Attempt[]>>((acc, attempt) => {
    const key = attempt.userName
    const bucket = acc[key] ?? []
    bucket.push(attempt)
    acc[key] = bucket
    return acc
  }, {})

  return Object.entries(grouped)
    .map(([name, userAttempts]) => {
      const best = Math.max(...userAttempts.map((item) => item.score))
      const avg = Math.round(userAttempts.reduce((sum, item) => sum + item.score, 0) / userAttempts.length)
      return { name, best, avg, attempts: userAttempts.length }
    })
    .sort((a, b) => b.best - a.best || b.avg - a.avg)
})

const topSprintResults = computed(() =>
  [...sprintResults.value].sort((a, b) => b.score - a.score || b.total - a.total).slice(0, 8),
)

const filteredReviewItems = computed(() => {
  if (!examReview.value) {
    return []
  }

  if (reviewFilter.value === 'wrong') {
    return examReview.value.items.filter((item) => !item.isCorrect)
  }

  if (reviewFilter.value === 'correct') {
    return examReview.value.items.filter((item) => item.isCorrect)
  }

  return examReview.value.items
})

const weakTopics = computed(() => {
  if (!examReview.value) {
    return []
  }

  const grouped = examReview.value.items.reduce<Record<string, number>>((acc, item) => {
    if (item.isCorrect) {
      return acc
    }

    acc[item.topic] = (acc[item.topic] ?? 0) + 1
    return acc
  }, {})

  return Object.entries(grouped)
    .map(([topic, wrong]) => ({ topic, wrong }))
    .sort((a, b) => b.wrong - a.wrong)
})

const learningErrorPool = computed(() => {
  const latestByQuestion = new Map<string, LearningRecord>()
  for (const record of learningRecords.value) {
    if (!latestByQuestion.has(record.questionId)) {
      latestByQuestion.set(record.questionId, record)
    }
  }

  return [...latestByQuestion.values()].filter((record) => !record.isCorrect)
})

const currentLearningQuestion = computed(() => learningQueue.value[learningIndex.value] ?? null)

const isExpanded = (questionId: string): boolean => expandedReviewIds.value.includes(questionId)

const toggleReviewItem = (questionId: string): void => {
  if (isExpanded(questionId)) {
    expandedReviewIds.value = expandedReviewIds.value.filter((id) => id !== questionId)
    return
  }

  expandedReviewIds.value = [...expandedReviewIds.value, questionId]
}

const startLearningByErrors = (): void => {
  learningQueue.value = shuffle(learningErrorPool.value)
  learningIndex.value = 0
  learningSelectedOptionId.value = null
  learningAnswered.value = 0
  learningCorrect.value = 0
  learningFinished.value = learningQueue.value.length === 0
}

const answerLearningQuestion = (optionId: string): void => {
  if (!currentLearningQuestion.value || learningSelectedOptionId.value) {
    return
  }

  learningSelectedOptionId.value = optionId
  learningAnswered.value += 1
  const isCorrect = currentLearningQuestion.value.correctOptionId === optionId
  if (isCorrect) {
    learningCorrect.value += 1
  }

  const record: LearningRecord = {
    id: crypto.randomUUID(),
    attemptId: `learning-${Date.now()}`,
    questionId: currentLearningQuestion.value.questionId,
    topic: currentLearningQuestion.value.topic,
    prompt: currentLearningQuestion.value.prompt,
    options: currentLearningQuestion.value.options,
    correctOptionId: currentLearningQuestion.value.correctOptionId,
    selectedOptionId: optionId,
    isCorrect,
    createdAt: new Date().toISOString(),
  }

  learningRecords.value = saveLearningRecords([record])
}

const nextLearningQuestion = (): void => {
  if (learningIndex.value >= learningQueue.value.length - 1) {
    learningFinished.value = true
    return
  }

  learningIndex.value += 1
  learningSelectedOptionId.value = null
}

const applyTheme = (value: Theme): void => {
  document.documentElement.setAttribute('data-theme', value)
  localStorage.setItem('pet-theme', value)
}

const toggleTheme = (): void => {
  theme.value = theme.value === 'dark' ? 'light' : 'dark'
}

const completeOnboarding = (): void => {
  const normalized = onboardingName.value.trim()
  if (!normalized || !onboardingAccepted.value) {
    return
  }

  userName.value = normalized
  onboardingDone.value = true
  localStorage.setItem('pet-user-name', normalized)
  localStorage.setItem('pet-onboarding-done', '1')
}

const loadBackendData = async (): Promise<void> => {
  try {
    const [remoteExams, remoteAttempts, remoteStats] = await Promise.all([
      fetchExams(),
      fetchAttempts(),
      fetchUserStats(),
    ])
    examBank.value = remoteExams
    attempts.value = remoteAttempts
    userStats.value = remoteStats
  } catch {
    examBank.value = import.meta.env.DEV ? seedExams : []
  }
}

const formatSeconds = (value: number): string => {
  const minutes = Math.floor(value / 60)
  const seconds = value % 60
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
}

const formatDate = (value: string): string =>
  new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(value))

const shuffle = <T>(items: T[]): T[] => {
  const copy = [...items]
  for (let i = copy.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1))
    const current = copy[i] as T
    copy[i] = copy[j] as T
    copy[j] = current
  }
  return copy
}

const getExamStats = (examId: string) => {
  const items = attempts.value.filter((attempt) => attempt.examId === examId)
  if (!items.length) {
    return { tries: 0, best: 0 }
  }

  return {
    tries: items.length,
    best: Math.max(...items.map((item) => item.score)),
  }
}

const getSubjectBadgeStyle = (exam: Exam): Record<string, string> => {
  const color = exam.subjectColor && /^#[0-9a-fA-F]{6}$/.test(exam.subjectColor) ? exam.subjectColor : '#2563eb'
  return { '--subject-color': color }
}

const startExam = (exam: Exam): void => {
  if (exam.questions.length === 0) {
    return
  }

  activeExam.value = exam
  questionIndex.value = 0
  answers.value = {}
  examElapsedSeconds.value = 0
  examStartedAt.value = Date.now()
  lastAttempt.value = null
  examReview.value = null
  reviewFilter.value = 'all'
  expandedReviewIds.value = []

  clearInterval(examTimer)
  examTimer = window.setInterval(() => {
    examElapsedSeconds.value += 1
    if (examTimeLeft.value === 0) {
      finishExam()
    }
  }, 1000)
}

const cancelExam = (): void => {
  activeExam.value = null
  questionIndex.value = 0
  answers.value = {}
  examElapsedSeconds.value = 0
  clearInterval(examTimer)
}

const answerQuestion = (questionId: string, optionId: string): void => {
  answers.value = { ...answers.value, [questionId]: optionId }
}

const nextQuestion = (): void => {
  if (!activeExam.value) {
    return
  }

  if (questionIndex.value < activeExam.value.questions.length - 1) {
    questionIndex.value += 1
  }
}

const previousQuestion = (): void => {
  if (questionIndex.value > 0) {
    questionIndex.value -= 1
  }
}

const finishExam = async (): Promise<void> => {
  if (!activeExam.value || !examStartedAt.value) {
    return
  }

  clearInterval(examTimer)

  const exam = activeExam.value
  const payloadAnswers = Object.entries(answers.value).reduce<Record<string, number>>((acc, [questionId, optionId]) => {
    const parsed = Number(optionId)
    if (!Number.isNaN(parsed)) {
      acc[questionId] = parsed
    }
    return acc
  }, {})

  try {
    const result = await submitAttempt(exam.id, {
      user_name: userName.value.trim() || 'Student',
      started_at: new Date(examStartedAt.value).toISOString(),
      duration_seconds: examElapsedSeconds.value,
      answers: payloadAnswers,
    })

    const attempt: Attempt = {
      id: String(result.attempt.id),
      examId: String(result.attempt.exam),
      examTitle: result.attempt.exam_title,
      userName: result.attempt.user_name,
      startedAt: result.attempt.started_at,
      finishedAt: result.attempt.finished_at,
      score: result.attempt.score,
      scoringPoints: result.attempt.scoring_points,
      maxScoringPoints: result.attempt.max_scoring_points,
      total: result.attempt.total_questions,
      durationSeconds: result.attempt.duration_seconds,
    }

    attempts.value = [attempt, ...attempts.value]
    userStats.value = await fetchUserStats()
    lastAttempt.value = attempt

    const questionById = new Map(exam.questions.map((question) => [Number(question.id), question]))
    learningRecords.value = saveLearningRecords(
      result.reviews.map((review) => {
        const question = questionById.get(review.question_id)
        const selectedOptionId = review.selected_option_id ? String(review.selected_option_id) : ''
        return {
          id: crypto.randomUUID(),
          attemptId: String(result.attempt.id),
          questionId: String(review.question_id),
          topic: review.topic,
          prompt: review.prompt,
          options: question?.options ?? [],
          correctOptionId: String(review.correct_option_id),
          selectedOptionId,
          isCorrect: review.is_correct,
          createdAt: result.attempt.finished_at,
        }
      }),
    )

    examReview.value = {
      attempt,
      examTitle: result.exam_title,
      passingScore: result.passing_score,
      scoringPoints: result.attempt.scoring_points,
      maxScoringPoints: result.attempt.max_scoring_points,
      correctCount: result.attempt.correct_count,
      total: result.attempt.total_questions,
      items: result.reviews.map((review, index) => ({
        questionNumber: index + 1,
        questionId: String(review.question_id),
        topic: review.topic,
        prompt: review.prompt,
        explanation: review.explanation,
        scoreValue: review.score_value,
        selectedText: review.selected_text,
        correctText: review.correct_text,
        isCorrect: review.is_correct,
      })),
    }

    reviewFilter.value = result.attempt.correct_count === result.attempt.total_questions ? 'all' : 'wrong'
    const firstWrong = result.reviews.find((review) => !review.is_correct)
    expandedReviewIds.value = firstWrong ? [String(firstWrong.question_id)] : []
  } catch {
    // Fallback to local static data if API is unavailable.
    const hasLocalCorrectAnswers = exam.questions.every((question) => Boolean(question.correctOptionId))
    const correct = exam.questions.reduce((sum, question) => {
      return sum + (answers.value[question.id] === question.correctOptionId ? 1 : 0)
    }, 0)
    const score = Math.round((correct / exam.questions.length) * 100)
    const attempt: Attempt = {
      id: crypto.randomUUID(),
      examId: exam.id,
      examTitle: exam.title,
      userName: userName.value.trim() || 'Student',
      startedAt: new Date(examStartedAt.value).toISOString(),
      finishedAt: new Date().toISOString(),
      score,
      scoringPoints: exam.questions.reduce(
        (sum, question) => sum + (answers.value[question.id] === question.correctOptionId ? question.scoreValue ?? 1 : 0),
        0,
      ),
      maxScoringPoints: exam.questions.reduce((sum, question) => sum + (question.scoreValue ?? 1), 0),
      total: exam.questions.length,
      durationSeconds: examElapsedSeconds.value,
    }
    attempts.value = [attempt, ...attempts.value]
    lastAttempt.value = attempt

    if (hasLocalCorrectAnswers) {
      const reviewItems = exam.questions.map((question, index) => {
        const selectedId = answers.value[question.id]
        const selectedText = question.options.find((option) => option.id === selectedId)?.text ?? 'РќРµ РІС‹Р±СЂР°РЅ'
        const correctText =
          question.options.find((option) => option.id === question.correctOptionId)?.text ?? 'РќРµ Р·Р°РґР°РЅ'
        return {
          questionNumber: index + 1,
          questionId: question.id,
          topic: question.topic,
          prompt: question.prompt,
          explanation: question.explanation ?? `Р’РµСЂРЅС‹Р№ РІР°СЂРёР°РЅС‚: ${correctText}`,
          scoreValue: question.scoreValue ?? 1,
          selectedText,
          correctText,
          isCorrect: selectedId === question.correctOptionId,
        }
      })

      examReview.value = {
        attempt,
        examTitle: exam.title,
        passingScore: exam.passingScore,
        scoringPoints: attempt.scoringPoints ?? 0,
        maxScoringPoints: attempt.maxScoringPoints ?? 0,
        correctCount: correct,
        total: exam.questions.length,
        items: reviewItems,
      }

      reviewFilter.value = correct === exam.questions.length ? 'all' : 'wrong'
      const firstWrong = reviewItems.find((item) => !item.isCorrect)
      expandedReviewIds.value = firstWrong ? [firstWrong.questionId] : []
    } else {
      examReview.value = null
    }
  }

  activeExam.value = null
  questionIndex.value = 0
  answers.value = {}
  examElapsedSeconds.value = 0
}

const nextSprintQuestion = (): void => {
  const questions = allQuestions.value
  const index = Math.floor(Math.random() * questions.length)
  sprintQuestion.value = questions[index] ?? null
}

const startSprint = (): void => {
  if (allQuestions.value.length === 0) {
    return
  }

  sprintActive.value = true
  sprintTimeLeft.value = sprintDurationSeconds
  sprintScore.value = 0
  sprintAnswered.value = 0
  nextSprintQuestion()

  clearInterval(sprintTimer)
  sprintTimer = window.setInterval(() => {
    sprintTimeLeft.value -= 1
    if (sprintTimeLeft.value <= 0) {
      finishSprint()
    }
  }, 1000)
}

const answerSprint = (optionId: string): void => {
  if (!sprintActive.value || !sprintQuestion.value) {
    return
  }

  sprintAnswered.value += 1
  if (sprintQuestion.value.correctOptionId === optionId) {
    sprintScore.value += 1
  }

  nextSprintQuestion()
}

const finishSprint = (): void => {
  if (!sprintActive.value) {
    return
  }

  clearInterval(sprintTimer)
  sprintActive.value = false

  const result: SprintResult = {
    id: crypto.randomUUID(),
    userName: userName.value.trim() || 'Student',
    score: sprintScore.value,
    total: sprintAnswered.value,
    startedAt: new Date(Date.now() - (sprintDurationSeconds - sprintTimeLeft.value) * 1000).toISOString(),
    finishedAt: new Date().toISOString(),
  }

  sprintResults.value = saveSprintResult(result)
}

watch(theme, (value) => applyTheme(value))
watch(userName, (value) => {
  const normalized = value.trim()
  if (normalized) {
    localStorage.setItem('pet-user-name', normalized)
  }
})

onMounted(() => {
  applyTheme(theme.value)
  void loadBackendData()
})

onBeforeUnmount(() => {
  clearInterval(examTimer)
  clearInterval(sprintTimer)
})
</script>

<template>
  <div class="app-shell">
    <section v-if="!onboardingDone" class="onboarding-wrap">
      <article class="card onboarding-card">
        <div class="onboarding-top">
          <h1>Р”РѕР±СЂРѕ РїРѕР¶Р°Р»РѕРІР°С‚СЊ</h1>
        </div>
        <p class="lead">РџРµСЂРµРґ РЅР°С‡Р°Р»РѕРј СѓРєР°Р¶Рё РёРјСЏ Рё РѕР·РЅР°РєРѕРјСЊСЃСЏ СЃ РїСЂР°РІРёР»Р°РјРё РїСЂРѕС…РѕР¶РґРµРЅРёСЏ С‚РµСЃС‚РѕРІ.</p>
        <label class="username-field">
          РљР°Рє РІР°СЃ Р·РѕРІСѓС‚
          <input v-model="onboardingName" type="text" maxlength="30" placeholder="РќР°РїСЂРёРјРµСЂ, РђРЅРЅР°" />
        </label>
        <ul class="rules-list">
          <li>РЈ РєР°Р¶РґРѕРіРѕ С‚РµСЃС‚Р° РµСЃС‚СЊ С‚Р°Р№РјРµСЂ Рё РїРѕСЂРѕРі РїСЂРѕС…РѕР¶РґРµРЅРёСЏ.</li>
          <li>РџРѕСЃР»Рµ Р·Р°РІРµСЂС€РµРЅРёСЏ РІС‹ СѓРІРёРґРёС‚Рµ РґРµС‚Р°Р»СЊРЅС‹Р№ СЂР°Р·Р±РѕСЂ РѕС‚РІРµС‚РѕРІ.</li>
          <li>РћС€РёР±РєРё Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РїРѕРїР°РґСѓС‚ РІ СЂР°Р·РґРµР» РѕР±СѓС‡РµРЅРёСЏ.</li>
          <li>Р РµР·СѓР»СЊС‚Р°С‚С‹ СЃРѕС…СЂР°РЅСЏСЋС‚СЃСЏ Р»РѕРєР°Р»СЊРЅРѕ РІ СЌС‚РѕРј Р±СЂР°СѓР·РµСЂРµ.</li>
        </ul>
        <label class="accept-row">
          <input v-model="onboardingAccepted" type="checkbox" />
          <span>РЇ РѕР·РЅР°РєРѕРјРёР»СЃСЏ СЃ РїСЂР°РІРёР»Р°РјРё</span>
        </label>
        <button class="cta" :disabled="!onboardingName.trim() || !onboardingAccepted" @click="completeOnboarding">
          РџСЂРѕРґРѕР»Р¶РёС‚СЊ
        </button>
      </article>
    </section>

    <div v-else>
    <div class="app-topbar">
      <span class="app-topbar-user">{{ userName }}</span>
      <button @click="toggleTheme">{{ theme === 'dark' ? 'РЎРІРµС‚Р»Р°СЏ С‚РµРјР°' : 'РўРµРјРЅР°СЏ С‚РµРјР°' }}</button>
    </div>
    <section v-if="tab === 'catalog' && !activeExam && examReview" class="panel-stack">
      <article class="card result-page">
        <h2>{{ examReview.examTitle }}: СЂРµР·СѓР»СЊС‚Р°С‚С‹</h2>
        <div class="result-overview">
          <div class="overview-item highlight">
            <span>РЎРєРѕСЂРёРЅРіРѕРІС‹Р№ Р±Р°Р»Р»</span>
            <strong>{{ examReview.scoringPoints }} / {{ examReview.maxScoringPoints }}</strong>
          </div>
          <div class="overview-item">
            <span>РЎС‡РµС‚</span>
            <strong>{{ examReview.attempt.score }}%</strong>
          </div>
          <div class="overview-item">
            <span>Р’РµСЂРЅС‹С…</span>
            <strong>{{ examReview.correctCount }}/{{ examReview.total }}</strong>
          </div>
          <div class="overview-item">
            <span>РџРѕСЂРѕРі</span>
            <strong>{{ examReview.passingScore }}%</strong>
          </div>
          <div class="overview-item">
            <span>РЎС‚Р°С‚СѓСЃ</span>
            <strong :class="{ success: examReview.attempt.score >= examReview.passingScore, fail: examReview.attempt.score < examReview.passingScore }">
              {{ examReview.attempt.score >= examReview.passingScore ? 'РџСЂРѕР№РґРµРЅРѕ' : 'РќРµ РїСЂРѕР№РґРµРЅРѕ' }}
            </strong>
          </div>
          <div class="overview-item meta-item">
            <span>Р’СЂРµРјСЏ</span>
            <strong>{{ formatSeconds(examReview.attempt.durationSeconds) }}</strong>
          </div>
          <div class="overview-item meta-item">
            <span>Р”Р°С‚Р°</span>
            <strong>{{ formatDate(examReview.attempt.finishedAt) }}</strong>
          </div>
        </div>
        <article class="recommend-card">
          <h3>Р РµРєРѕРјРµРЅРґР°С†РёРё РґР»СЏ СЃР°РјРѕРѕР±СЂР°Р·РѕРІР°РЅРёСЏ</h3>
          <p v-if="!weakTopics.length" class="muted">РћС€РёР±РѕРє РЅРµС‚. РџРѕРїСЂРѕР±СѓР№ СѓСЃР»РѕР¶РЅРµРЅРЅС‹Р№ С‚РµСЃС‚ РёР»Рё СЃРїСЂРёРЅС‚-СЂРµР¶РёРј.</p>
          <ul v-else class="recommend-list">
            <li v-for="topic in weakTopics.slice(0, 3)" :key="topic.topic">
              РўРµРјР° <strong>{{ topic.topic }}</strong>: {{ topic.wrong }} РѕС€РёР±РѕРє. Р РµРєРѕРјРµРЅРґСѓРµС‚СЃСЏ РїСЂРѕР№С‚Рё С‚СЂРµРЅРёСЂРѕРІРєСѓ РїРѕ РѕС€РёР±РєР°Рј.
            </li>
          </ul>
        </article>
        <div class="review-filters">
          <button :class="{ active: reviewFilter === 'all' }" @click="reviewFilter = 'all'">Р’СЃРµ</button>
          <button :class="{ active: reviewFilter === 'wrong' }" @click="reviewFilter = 'wrong'">РўРѕР»СЊРєРѕ РѕС€РёР±РєРё</button>
          <button :class="{ active: reviewFilter === 'correct' }" @click="reviewFilter = 'correct'">РўРѕР»СЊРєРѕ РІРµСЂРЅС‹Рµ</button>
          <button @click="expandedReviewIds = filteredReviewItems.map((item) => item.questionId)">Р Р°СЃРєСЂС‹С‚СЊ РІСЃРµ</button>
          <button @click="expandedReviewIds = []">РЎРІРµСЂРЅСѓС‚СЊ РІСЃРµ</button>
        </div>
        <div class="review-list">
          <p v-if="!filteredReviewItems.length" class="empty">РџРѕ С‚РµРєСѓС‰РµРјСѓ С„РёР»СЊС‚СЂСѓ РІРѕРїСЂРѕСЃРѕРІ РЅРµС‚.</p>
          <article
            v-for="item in filteredReviewItems"
            :key="item.questionId"
            class="review-item"
            :class="{ correct: item.isCorrect, wrong: !item.isCorrect }"
          >
            <div class="review-head">
              <p class="question-index">
                Р’РѕРїСЂРѕСЃ {{ item.questionNumber }}
                <span>{{ item.topic }}</span>
              </p>
              <div class="review-head-actions">
                <span class="review-status" :class="{ correct: item.isCorrect, wrong: !item.isCorrect }">
                  {{ item.isCorrect ? 'Р’РµСЂРЅРѕ' : 'РћС€РёР±РєР°' }}
                </span>
                <button class="review-toggle" @click="toggleReviewItem(item.questionId)">
                  {{ isExpanded(item.questionId) ? 'РЎРєСЂС‹С‚СЊ' : 'РџРѕРєР°Р·Р°С‚СЊ' }}
                </button>
              </div>
            </div>
            <h3>{{ item.prompt }}</h3>
            <div v-if="isExpanded(item.questionId)" class="answer-stack">
              <div class="answer-line correct">
                <span>РџСЂР°РІРёР»СЊРЅС‹Р№:</span>
                <strong>{{ item.correctText }}</strong>
              </div>
              <div class="answer-line" :class="{ wrong: !item.isCorrect }">
                <span>Р’Р°С€ РѕС‚РІРµС‚:</span>
                <strong>{{ item.selectedText }}</strong>
              </div>
              <div class="explanation-box">
                <span>РџРѕСЏСЃРЅРµРЅРёРµ</span>
                <p>{{ item.explanation }}</p>
                <small>Р‘Р°Р»Р»С‹ Р·Р° РІРѕРїСЂРѕСЃ: {{ item.scoreValue }}</small>
              </div>
            </div>
          </article>
        </div>
      </article>
      <button class="cta result-back-btn" @click="examReview = null">РћР±СЂР°С‚РЅРѕ Рє С‚РµСЃС‚Р°Рј</button>
    </section>

    <section v-if="tab === 'catalog' && !activeExam && !examReview" class="panel-stack">
      <article v-if="lastAttempt" class="card result-card">
        <h2>{{ lastAttempt.examTitle }} Р·Р°РІРµСЂС€РµРЅ</h2>
        <p class="result-score" :class="{ success: lastAttempt.score >= 70 }">{{ lastAttempt.score }}%</p>
        <p>
          Р’СЂРµРјСЏ: {{ formatSeconds(lastAttempt.durationSeconds) }} В· Р”Р°С‚Р°: {{ formatDate(lastAttempt.finishedAt) }}
        </p>
      </article>

      <div class="catalog-toolbar card">
        <h2>РљР°С‚Р°Р»РѕРі СЌРєР·Р°РјРµРЅРѕРІ</h2>
        <div class="chips">
          <button
            v-for="subject in subjects"
            :key="subject"
            :class="{ active: selectedSubject === subject }"
            @click="selectedSubject = subject"
          >
            {{ subject === 'all' ? 'Р’СЃРµ РЅР°РїСЂР°РІР»РµРЅРёСЏ' : subject }}
          </button>
        </div>
      </div>

      <div class="exam-grid">
        <article v-for="exam in filteredExams" :key="exam.id" class="card exam-card">
          <div class="exam-meta">
            <span class="subject-pill" :style="getSubjectBadgeStyle(exam)">{{ exam.subject }}</span>
            <span>{{ exam.durationMinutes }} РјРёРЅ</span>
          </div>
          <h3>{{ exam.title }}</h3>
          <p>{{ exam.description }}</p>
          <div class="exam-stats">
            <div class="exam-stat">
              <span>Р’РѕРїСЂРѕСЃРѕРІ</span>
              <strong>{{ exam.questions.length }}</strong>
            </div>
            <div class="exam-stat">
              <span>РџРѕСЂРѕРі</span>
              <strong>{{ exam.passingScore }}%</strong>
            </div>
            <div class="exam-stat">
              <span>Р РµРєРѕСЂРґ</span>
              <strong>{{ getExamStats(exam.id).best }}%</strong>
            </div>
          </div>
          <button class="cta" :disabled="exam.questions.length === 0" @click="startExam(exam)">
            {{ exam.questions.length === 0 ? 'РќРµС‚ РіРѕС‚РѕРІС‹С… РІРѕРїСЂРѕСЃРѕРІ' : 'РќР°С‡Р°С‚СЊ' }}
          </button>
        </article>
      </div>

      <article class="card history-card">
        <h2>РџРѕСЃР»РµРґРЅРёРµ РїРѕРїС‹С‚РєРё</h2>
        <div v-if="attempts.length" class="history-list">
          <div v-for="attempt in attempts.slice(0, 6)" :key="attempt.id" class="history-item">
            <span>{{ attempt.examTitle }}</span>
            <strong>{{ attempt.score }}%</strong>
            <span>{{ attempt.userName }}</span>
            <time>{{ formatDate(attempt.finishedAt) }}</time>
          </div>
        </div>
        <p v-else class="empty">РџРѕРєР° РЅРµС‚ РїРѕРїС‹С‚РѕРє.</p>
      </article>
    </section>

    <section v-if="tab === 'catalog' && activeExam" class="panel-stack">
      <article class="card exam-session">
        <div class="session-layout">
          <div v-if="currentQuestion" :key="currentQuestion.id" class="question-block">
            <p class="question-index">
              Р’РѕРїСЂРѕСЃ {{ questionIndex + 1 }} / {{ activeExam.questions.length }}
              <span>{{ currentQuestion.topic }}</span>
            </p>
            <h3>{{ currentQuestion.prompt }}</h3>

            <div class="options">
              <button
                v-for="option in currentQuestion.options"
                :key="option.id"
                :class="{ selected: answers[currentQuestion.id] === option.id }"
                @click="answerQuestion(currentQuestion.id, option.id)"
              >
                {{ option.text }}
              </button>
            </div>
          </div>

          <aside class="session-sidebar">
            <h2>{{ activeExam.title }}</h2>
            <div class="timer">{{ formatSeconds(examTimeLeft) }}</div>

            <div class="progress-row">
              <span>РџСЂРѕРіСЂРµСЃСЃ</span>
              <strong>{{ progress }}%</strong>
            </div>
            <div class="progress-row">
              <span>РћС‚РІРµС‚С‹</span>
              <strong>{{ committedAnsweredCount }}/{{ activeExam.questions.length }}</strong>
            </div>
            <div class="progress-track">
              <div class="progress-bar" :style="{ width: `${progress}%` }"></div>
            </div>

            <div class="session-actions">
              <button :disabled="questionIndex === 0" @click="previousQuestion">РќР°Р·Р°Рґ</button>
              <button
                v-if="questionIndex < activeExam.questions.length - 1"
                :disabled="!currentQuestion || !answers[currentQuestion.id]"
                class="cta"
                @click="nextQuestion"
              >
                Р”Р°Р»РµРµ
              </button>
              <button
                v-else
                :disabled="!currentQuestion || !answers[currentQuestion.id]"
                class="cta"
                @click="finishExam"
              >
                Р—Р°РІРµСЂС€РёС‚СЊ
              </button>
            </div>
          </aside>
        </div>
      </article>
      <button class="cancel-link" @click="cancelExam">РћС‚РјРµРЅР°</button>
    </section>

    <section v-if="tab === 'learning' && !activeExam" class="panel-stack">
      <article class="card learning-card">
        <h2>РўСЂРµРЅРёСЂРѕРІРєР° РїРѕ РѕС€РёР±РєР°Рј</h2>
        <p class="muted">
          Р’ РїСѓР»Рµ РґР»СЏ С‚СЂРµРЅРёСЂРѕРІРєРё: <strong>{{ learningErrorPool.length }}</strong> РІРѕРїСЂРѕСЃРѕРІ РёР· РїСЂРѕС€Р»С‹С… РїРѕРїС‹С‚РѕРє.
        </p>
        <button class="cta" :disabled="!learningErrorPool.length" @click="startLearningByErrors">РќР°С‡Р°С‚СЊ С‚СЂРµРЅРёСЂРѕРІРєСѓ</button>
      </article>

      <article v-if="learningQueue.length" class="card learning-card">
        <div v-if="!learningFinished && currentLearningQuestion">
          <p class="question-index">
            РўСЂРµРЅРёСЂРѕРІРєР°: {{ learningIndex + 1 }} / {{ learningQueue.length }}
            <span>{{ currentLearningQuestion.topic }}</span>
          </p>
          <h3>{{ currentLearningQuestion.prompt }}</h3>
          <div class="options">
            <button
              v-for="option in currentLearningQuestion.options"
              :key="option.id"
              :class="{
                selected: learningSelectedOptionId === option.id,
                correct: learningSelectedOptionId && option.id === currentLearningQuestion.correctOptionId,
                wrong:
                  learningSelectedOptionId === option.id && option.id !== currentLearningQuestion.correctOptionId,
              }"
              :disabled="Boolean(learningSelectedOptionId)"
              @click="answerLearningQuestion(option.id)"
            >
              {{ option.text }}
            </button>
          </div>
          <div class="editor-actions">
            <button class="cta" :disabled="!learningSelectedOptionId" @click="nextLearningQuestion">Р”Р°Р»СЊС€Рµ</button>
          </div>
        </div>

        <div v-else class="learning-summary">
          <h3>РўСЂРµРЅРёСЂРѕРІРєР° Р·Р°РІРµСЂС€РµРЅР°</h3>
          <p>
            Р’РµСЂРЅРѕ: <strong>{{ learningCorrect }}</strong> РёР· <strong>{{ learningAnswered }}</strong>
          </p>
          <button class="cta" :disabled="!learningErrorPool.length" @click="startLearningByErrors">
            РџСЂРѕР№С‚Рё Р·Р°РЅРѕРІРѕ
          </button>
        </div>
      </article>
    </section>

    <section v-if="tab === 'leaderboard' && !activeExam" class="panel-stack">
      <article class="card">
        <h2>Р›РёРґРµСЂР±РѕСЂРґ СѓС‡Р°СЃС‚РЅРёРєРѕРІ</h2>
        <div v-if="leaderboard.length" class="leaderboard">
          <div class="leaderboard-head">
            <span>РЈС‡Р°СЃС‚РЅРёРє</span>
            <span>Best</span>
            <span>Avg</span>
            <span>РџРѕРїС‹С‚РѕРє</span>
          </div>
          <div v-for="entry in leaderboard" :key="entry.name" class="leaderboard-row">
            <span>{{ entry.name }}</span>
            <strong>{{ entry.best }}%</strong>
            <span>{{ entry.avg }}%</span>
            <span>{{ entry.attempts }}</span>
          </div>
        </div>
        <p v-else class="empty">РџРѕРєР° РїСѓСЃС‚Рѕ.</p>
      </article>
    </section>

    <section v-if="tab === 'sprint' && !activeExam" class="panel-stack">
      <article class="card sprint-card">
        <h2>РЎРїСЂРёРЅС‚ РЅР° 60 СЃРµРєСѓРЅРґ</h2>
        <div class="sprint-meta">
          <strong>{{ formatSeconds(sprintTimeLeft) }}</strong>
          <span>РЎС‡РµС‚: {{ sprintScore }} / {{ sprintAnswered }}</span>
        </div>

        <button v-if="!sprintActive" class="cta" :disabled="!allQuestions.length" @click="startSprint">РЎС‚Р°СЂС‚</button>
        <button v-else @click="finishSprint">Р—Р°РІРµСЂС€РёС‚СЊ</button>

        <div v-if="sprintActive && sprintQuestion" class="sprint-question">
          <p class="question-index">{{ sprintQuestion.topic }}</p>
          <h3>{{ sprintQuestion.prompt }}</h3>
          <div class="options">
            <button v-for="option in sprintQuestion.options" :key="option.id" @click="answerSprint(option.id)">
              {{ option.text }}
            </button>
          </div>
        </div>
      </article>

      <article class="card history-card">
        <h2>РўРѕРї СЃРїСЂРёРЅС‚РѕРІ</h2>
        <div v-if="topSprintResults.length" class="history-list">
          <div v-for="item in topSprintResults" :key="item.id" class="history-item">
            <span>{{ item.userName }}</span>
            <strong>{{ item.score }} / {{ item.total }}</strong>
            <span></span>
            <time>{{ formatDate(item.finishedAt) }}</time>
          </div>
        </div>
        <p v-else class="empty">Р РµР·СѓР»СЊС‚Р°С‚РѕРІ РїРѕРєР° РЅРµС‚.</p>
      </article>
    </section>
    </div>
  </div>
</template>
