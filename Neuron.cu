
#include <iostream>
#include <sstream>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/transform.h>
#include <thrust/copy.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/functional.h>

#include "Neuron.cuh"

using std::vector;
using std::random_device;
using std::mt19937;
using std::uniform_real_distribution;
using std::max;
using std::string;
using std::stringstream;


struct learn_m_functor {
  const double delta;
  const double beta_one;

  learn_m_functor(double _delta, double _beta_one) {
    delta = _delta;
    beta_one = _beta_one;
  }

  __host__ __device__ double operator()(const double& m, const double& inputValue) const {
    return beta_one * m + (1 - beta_one) * (delta * inputValue);
  }
};


struct learn_nu_functor {
  const double delta;
  const double beta_two;

  learn_nu_functor(double _delta, double _beta_two) {
    delta = _delta;
    beta_two = _beta_two;
  }

  __host__ __device__ double operator()(const double& nu, const double& inputValue) const {
    return beta_two * nu + (1 - beta_two) * pow((delta * inputValue), 2);
  }
};


struct learn_functor {
  const double beta_one;
  const double beta_two;
  const unsigned long iteration;
  const double epsilon;
  const double alpha;

  learn_functor(double _beta_one, double _beta_two, unsigned long _iteration, double _epsilon, double _alpha) {
    beta_one = _beta_one;
    beta_two = _beta_two;
    iteration = _iteration;
    epsilon = _epsilon;
    alpha = _alpha;
  }

  __host__ __device__ double operator()(const double& m, const double& nu) {
    return alpha * ((m / (1 - pow(beta_one, iteration))) / (sqrt(nu / (1 - pow(beta_two, iteration))) + epsilon));
  }
};


struct output_functor {
  const double dropout_rate;

  output_functor(double _dropout_rate){
    dropout_rate = _dropout_rate;
  }

  __host__ __device__ double operator()(const double& inputValue, const double& weight) const {
    return inputValue * (weight * (1.0 - dropout_rate));
  }
};


/**
 * vectorのサイズ確保のためだけに用いるNeuronのデフォルトコンストラクタ
 * @return Neuronのインスタンス
 */
Neuron::Neuron() {}

/**
 * Neuronのコンストラクタ
 * @param num_input 入力ニューロン数（入力データ数）
 * @param dropout_rate Dropout率
 * @return Neuronのインスタンス
 */
Neuron::Neuron(const unsigned long num_input, const vector<double> &weight,
               const vector<double> &m, const vector<double> &nu,
               const unsigned long iteration, const double bias, const int activation_type,
               const double dropout_rate) {
  this->num_input = num_input; // このニューロンへの入力数（前の層のニューロン数）
  this->activation_type = activation_type;
  this->dropout_rate = dropout_rate;
  random_device rnd; // 非決定的乱数生成器
  mt19937 mt; // メルセンヌ・ツイスタ
  mt.seed(rnd());
  uniform_real_distribution<double> real_rnd(0.0, 1.0);

  if (bias != 0.0) this->bias = bias;
  else this->bias = real_rnd(mt); // バイアスを乱数で設定

  // Adamの各パラメータについて，学習済みのものが渡されていればセットし，そうでなければ0.0で初期化
  if (iteration != 0) this->iteration = iteration;
  else this->iteration = 0;


  if (m.size() > 0) this->m = vector<double>(m);
  else this->m = vector<double>(num_input, 0.0);

  if (nu.size() > 0) this->nu = vector<double>(nu);
  else this->nu = vector<double>(num_input, 0.0);

  // 結合荷重が渡されていればそれをセットし，無ければ乱数で初期化
  if (weight.size() > 0) this->inputWeights = vector<double>(weight);
  else {
    this->inputWeights.resize(num_input);
    for (int i = 0; i < this->num_input; ++i) this->inputWeights[i] = real_rnd(mt);
  }
}

/**
 * 受け取った0.0以上1.0未満の乱数値からdropout_maskを設定する
 * @param random_value 0.0以上1.0未満の乱数値
 */
void Neuron::dropout(const double random_value) {
  if (random_value < dropout_rate) this->dropout_mask = 0.0;
  else this->dropout_mask = 1.0;
}

/**
 * dropout_maskが1.0であれば，Adamを用いてニューロンの結合荷重を学習し，確率的勾配降下でバイアスを更新する
 * @param delta 損失関数を偏微分したもの（これに一つ前の層の出力データを掛けて傾きを得る）
 * @param inputValues 一つ前の層の出力データ
 */
void Neuron::learn(const double delta, const vector<double> &inputValues) {
  this->delta = delta;

  // Adamを用いて重み付けを学習する
  if (this->dropout_mask == 1.0) {
    this->iteration += 1;

    // allocate device side inputValues
    thrust::device_vector<double> d_inputValues(inputValues.begin(), inputValues.end());

    // allocate device side m
    thrust::device_vector<double> d_m(m.begin(), m.end());

    // transform m inputValues using learn_m_functor
    thrust::transform(d_m.begin(), d_m.end(),
                      d_inputValues.begin(), d_m.begin(), learn_m_functor(delta, beta_one));

    // copy device side m to host side m
    thrust::copy(d_m.begin(), d_m.end(), m.begin());


    thrust::device_vector<double> d_nu(nu.begin(), nu.end());
    thrust::transform(d_nu.begin(), d_nu.end(),
                      d_inputValues.begin(), d_nu.begin(), learn_nu_functor(delta, beta_two));
    thrust::copy(d_nu.begin(), d_nu.end(), nu.begin());

    thrust::device_vector<double> d_weight(inputWeights.begin(), inputWeights.end());
    thrust::transform(d_weight.begin(), d_weight.end(),
                      thrust::make_transform_iterator(d_m.begin(), d_nu.begin(),
                                        learn_functor(beta_one, beta_two, iteration, epsilon, alpha)),
                      d_weight.begin(), thrust::minus<double>());
    thrust::copy(d_weight.begin(), d_weight.end(), inputWeights.begin());


    // 確率的勾配降下でバイアスを更新
    this->bias -= (this->alpha * this->delta) - (this->alpha * this->rambda * this->bias);
  }
}

/**
 * ニューロンの出力メソッド．バイアスや重み付けにdropout_ratioを掛けて処理する
 * @param inputValues 一つ前の層の出力データ
 * @return ニューロンの出力値（活性化関数より得られた値）
 */
double Neuron::output(const vector<double> &inputValues) {
  double sum = this->bias * (1.0 - this->dropout_rate);

  thrust::device_vector<double> d_inputValues(inputValues.begin(), inputValues.end());
  thrust::device_vector<double> d_inputWeights(inputWeights.begin(), inputWeights.end());

  sum += thrust::reduce(
      thrust::make_transform_iterator(d_inputValues.begin(),
                                      d_inputWeights.begin(),
                                      output_functor(dropout_rate)),
      thrust::make_transform_iterator(d_inputValues.end(),
                                      d_inputWeights.end(),
                                      output_functor(dropout_rate)));

  double activated;
  if (activation_type == 0) activated = activation_identity(sum);
  else if (activation_type == 1) activated = activation_sigmoid(sum);
  else if (activation_type == 2) activated = activation_tanh(sum);
  else activated = activation_relu(sum);

  return activated;
}

/**
 * ニューロンの出力を得て，それにdropout_maskを掛ける
 * @param inputValues ニューロンの入力データ
 * @return ニューロンの出力
 */
double Neuron::learn_output(const vector<double> &inputValues) {
  // 入力側の細胞出力の重み付き和をとる
  double sum = this->bias;

  thrust::device_vector<double> d_inputValues(inputValues.begin(), inputValues.end());
  thrust::device_vector<double> d_inputWeights(inputWeights.begin(), inputWeights.end());

  sum += thrust::reduce(
      thrust::make_transform_iterator(d_inputValues.begin(),
                                      d_inputWeights.begin(),
                                      thrust::multiplies<double>()),
      thrust::make_transform_iterator(d_inputValues.end(),
                                      d_inputWeights.end(),
                                      thrust::multiplies<double>()));

  // 得られた重み付き和を活性化関数に入れて出力を得る
  double activated;
  if (activation_type == 0) activated = activation_identity(sum);
  else if (activation_type == 1) activated = activation_sigmoid(sum);
  else if (activation_type == 2) activated = activation_tanh(sum);
  else activated = activation_relu(sum);

  return activated * this->dropout_mask;
}

/**
 * 活性化関数：恒等写像
 * @param x 入力
 * @return 計算結果
 */
double Neuron::activation_identity(const double x) {
  return x;
}

/**
 * 活性化関数 : シグモイド関数
 * @param x 入力
 * @return 計算結果
 */
double Neuron::activation_sigmoid(const double x) {
  return 1.0 / (1.0 + pow(M_E, -x));
}

/**
 * 活性化関数 : tanh
 * @param x 入力
 * @return 計算結果
 */
double Neuron::activation_tanh(const double x) {
  return tanh(x);
}

/**
 * 活性化関数 : ランプ関数（ReLU）
 * @param x 入力
 * @return 計算結果
 */
double Neuron::activation_relu(const double x) {
  return max(0.0, x);
}

/**
 * このニューロンの指定された入力インデックスの結合荷重を返す
 * @param i 入力インデックス
 * @return 結合荷重
 */
double Neuron::getInputWeightIndexOf(const int i) {
  return this->inputWeights[i];
}

/**
 * 現在の修正量を返す
 * @return 修正量
 */
double Neuron::getDelta() {
  return this->delta;
}

/**
 * このニューロンの閾値を返す
 */
double Neuron::getBias() {
  return this->bias;
}

double Neuron::getMIndexOf(const int i) {
  return this->m[i];
}

double Neuron::getNuIndexOf(const int i) {
  return this->nu[i];
}

unsigned long Neuron::getIteration() {
  return this->iteration;
}

/**
 * このニューロンの結合荷重を文字列でまとめて返す
 * @return このニューロンの結合荷重をまとめた文字列
 */
string Neuron::toString() {
  stringstream ss;
  ss << "weight : ";
  for (int neuron = 0; neuron < num_input; ++neuron)
    ss << inputWeights[neuron] << " , ";

  string output = ss.str();
  return output;
}