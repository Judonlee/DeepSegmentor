----------------------------------------------------------------------
--require('mobdebug').start()
require 'torch'   -- torch
require 'nn'
require 'rnn'
require 'xlua'
dofile ('model/structured_hinge_loss.lua') -- new loss function
d = dofile('common/data.lua')
m = dofile('model/model.lua')
tr = dofile('train.lua')
eval = dofile('evaluate.lua')


----------------------------------------------------------------------
if not opt then
   print '==> processing options'
   cmd = torch.CmdLine()
   cmd:text()
   cmd:text('Bi-RNN for Audio Segmentation')
   cmd:text()
   cmd:text('Options:')

   -- general
   cmd:option('-seed', 1234, 'the seed to generate numbers')
   -- data
   cmd:option('-features_path', 'data/word_duration/small/', 'the path to the features file')
   cmd:option('-labels_path', 'data/word_duration/small/', 'the path to the labels file')
   cmd:option('-input_dim', 13, 'the input size')
   cmd:option('-n_frames', 4, 'the number of frames to concatenate')
   -- loss
   cmd:option('-eps', 0, 'the tolerance value for the loss function')
   -- model
   cmd:option('-hidden_size', 200, 'the hidden size')
   cmd:option('-dropout', 0.0, 'dropout rate')
   cmd:option('-n_layers', 1, 'the number of layers')
   -- train
   cmd:option('-save', 'results/', 'subdirectory to save/log experiments in')
   cmd:option('-plot', false, 'live plot')
   cmd:option('-optimization', 'ADAGRAD', 'optimization method: SGD | ADAM | ADAGRAD | RMSPROP | ADADELTA')
   cmd:option('-clipping', 10, 'gradient clipping in the range of [-n, n]')
   cmd:option('-learningRate', 0.01, 'learning rate at t=0')
   cmd:option('-weightDecay', 0, 'weight decay (SGD only)')
   cmd:option('-momentum', 0.8, 'momentum (SGD only)')
   cmd:option('-type', 'double', 'data type: double | cuda')
   cmd:option('-patience', 10, 'the number of epochs to be patience')
   cmd:option('-x_suffix', '.data', 'the suffix of the data files')
   cmd:option('-y_suffix', '.labels', 'the suffix of the label files')
   
   cmd:text()
   opt = cmd:parse(arg or {})
end

----------------------------------------------------------------------
-- define parameters
local time = 0
local iteration = 0  -- for early stopping
local epoch = 1  -- epoch tracker
local best_loss = 99999999
local best_score = -1
local score = -1
local loss = -1
train_folder = 'train/'
val_folder = 'val/'
test_folder = 'test/'

-- for CUDA
if opt.type == 'cuda' then
   print('==> switching to CUDA')
   require 'cunn'
   torch.setdefaulttensortype('torch.FloatTensor')
end

-- ========== create loggers and save the parameters ========== --
lossLogger = optim.Logger(paths.concat(opt.save, 'loss.log'))
scoreLogger = optim.Logger(paths.concat(opt.save, 'score.log'))

-- set seed and save the parameters for reproducibility
torch.manualSeed(opt.seed)
paramsLogger = io.open(paths.concat(opt.save, 'params.log'), 'w')
for key, value in pairs(opt) do
  paramsLogger:write(key .. ': ' .. tostring(value) .. '\n')
end
paramsLogger:close()

-- ============================ load the data ============================ --
print '==> Loading data set'
d:new(opt.x_suffix, opt.y_suffix)
x_train, y_train, f_n_train = d:read_data(paths.concat(opt.features_path, train_folder), paths.concat(opt.labels_path, train_folder), opt.input_dim, 'train.t7')
x_val, y_val, f_n_val = d:read_data(paths.concat(opt.features_path, val_folder), paths.concat(opt.labels_path, val_folder), opt.input_dim, 'val.t7')
x_test, y_test, f_n_test = d:read_data(paths.concat(opt.features_path, test_folder), paths.concat(opt.labels_path, test_folder), opt.input_dim, 'test.t7')

-- applying z-score normalization
mue, sigma = d:calc_z_score_params(x_train)
x_train = d:normalize(x_train, mue[1][1], sigma[1][1])
x_val = d:normalize(x_val, mue[1][1], sigma[1][1])
x_test = d:normalize(x_test, mue[1][1], sigma[1][1])

-- concat frames
x_train, y_train = d:concat_frames(x_train, y_train, opt.n_frames)
x_test, y_test = d:concat_frames(x_test, y_test, opt.n_frames)
x_val, y_val = d:concat_frames(x_val, y_val, opt.n_frames)

-- ========== define the model, loss and optimization technique ========== --
print '==> define loss'
criterion = nn.StructuredHingeLoss(opt.eps)
print(criterion)

print '==> build the model and initialize weights'
method = 'xavier'
model = m:build_model((2 * opt.n_frames + 1 ) * opt.input_dim, opt.hidden_size, opt.dropout, method, opt.n_layers)
print(model)

print '==> configuring optimizer'
tr:new(opt.type, opt.clipping)
tr:set_optimizer(opt.optimization)

-- Retrieve parameters and gradients
if model then
  parameters, gradParameters = model:getParameters()
end

-- ============================= training ================================ --
print '==> training! '
print '==> evaluating on validation set'

-- evaluate mode
--model:evaluate()
--loss, score, _ = eval:evaluate(model, criterion, x_val, y_val, f_n_val)

print('\n==> Average score: ' .. score)
print('==> Average cumulative loss: ' .. loss)

-- loop until convergence
while loss < best_loss or iteration <= opt.patience do
  -- training mode
  model:training()
  
  -- do full epoch
  print("==> online epoch # " .. epoch)
  for t=1, #x_train do
    xlua.progress(t, #x_train)
    time = time + tr:train(x_train[t], y_train[t])
  end  
  print("\n==> time to learn 1 sample = " .. (time*1000) .. 'ms')
  epoch = epoch + 1
  
  -- evaluate mode
  model:evaluate()
  print '==> evaluating on validation set'
  loss, score, _ = eval:evaluate(model, criterion, x_val, y_val, f_n_val)
  
  print('\n==> Average score: ' .. score)
  print('==> Average cumulative loss: ' .. loss)
  
  -- early stopping criteria
  if loss >= best_loss then     
    -- increase iteration number
    iteration = iteration + 1
    
    print('\n========================================')
    print('==> Loss did not improved, iteration: ' .. iteration)
    print('========================================\n')
  else
    -- update the best loss value
    best_loss = loss
    best_score = score
    
    -- clean state before saving
    model:clearState()
    model:get(1):forget()
    model:get(1).output = torch.Tensor()
    model:get(1).gradInput = torch.Tensor()
    
    -- save/log current net
    local filename = paths.concat(opt.save, 'model.net')
    os.execute('mkdir -p ' .. sys.dirname(filename))
    print('==> loss improved, saving model to '..filename)
    torch.save(filename, model)
    iteration = 0
  end
  
  -- update loggers
  lossLogger:add{['% loss (train set)'] = loss}
  scoreLogger:add{['% score (train set)'] = score}
end

-- update loggers for final results
lossLogger:add{['% loss (train set)'] = best_loss}
scoreLogger:add{['% score (train set)'] = best_score}

-- ============================== testing ================================ --
-- load the relevant model
local filename = paths.concat(opt.save, 'model.net')
model = torch.load(filename)

print '==> evaluating on test set'
eval:evaluate(model, criterion, x_test, y_test, f_n_test, true)
eval:evaluate(model, criterion, x_train, y_train, f_n_train, true)
